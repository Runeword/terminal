package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: git-branches <worktree|switch|merge|cherry-pick|diff-branches|worktree-remove|stash-apply>")
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "worktree":
		err = worktreeList()
	case "switch":
		err = switchBranch()
	case "merge":
		err = mergeBranch()
	case "cherry-pick":
		err = cherryPick()
	case "diff-branches":
		err = diffBranches()
	case "worktree-remove":
		err = worktreeRemove()
	case "stash-apply":
		err = stashApply()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func gitLines(args ...string) ([]string, error) {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return nil, err
	}
	s := strings.TrimRight(string(out), "\n")
	if s == "" {
		return nil, nil
	}
	return strings.Split(s, "\n"), nil
}

func gitLine(args ...string) (string, error) {
	out, err := exec.Command("git", args...).Output()
	return strings.TrimRight(string(out), "\n"), err
}

func getPager() string {
	p, _ := gitLine("config", "core.pager")
	if p == "" {
		return "cat"
	}
	return p
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

type branchInfo struct {
	current   string
	branches  []string
	worktrees map[string]string // branch → worktree path
	pager     string
}

// fetchBranches concurrently fetches the current branch, a filtered branch
// list, and the configured pager. It removes HEAD, symrefs, and (when
// dedupRemote is true) remote branches that have a local counterpart.
func fetchBranches(excludeCurrent, dedupRemote bool) (*branchInfo, error) {
	var current, pager string
	var raw []string
	var currentErr, rawErr error

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		current, currentErr = gitLine("rev-parse", "--abbrev-ref", "HEAD")
	}()
	go func() {
		defer wg.Done()
		raw, rawErr = gitLines("branch", "--all", "--format=%(refname:short)%09%(worktreepath)%09%(symref)")
	}()
	go func() {
		defer wg.Done()
		pager = getPager()
	}()
	wg.Wait()

	if currentErr != nil {
		return nil, currentErr
	}
	if rawErr != nil {
		return nil, rawErr
	}

	local := map[string]bool{}
	worktrees := map[string]string{}
	var all []string
	for _, line := range raw {
		parts := strings.SplitN(line, "\t", 3)
		branch := parts[0]
		worktree := ""
		symref := ""
		if len(parts) >= 2 {
			worktree = parts[1]
		}
		if len(parts) >= 3 {
			symref = parts[2]
		}
		if branch == "" || strings.HasPrefix(branch, "HEAD") || symref != "" {
			continue
		}
		if !strings.Contains(branch, "/") {
			local[branch] = true
		}
		if worktree != "" {
			worktrees[branch] = worktree
		}
		all = append(all, branch)
	}

	var filtered []string
	for _, b := range all {
		if excludeCurrent && b == current {
			continue
		}
		if dedupRemote {
			if idx := strings.Index(b, "/"); idx != -1 {
				if local[b[idx+1:]] {
					continue
				}
			}
		}
		filtered = append(filtered, b)
	}

	return &branchInfo{
		current:   current,
		branches:  filtered,
		worktrees: worktrees,
		pager:     pager,
	}, nil
}

// runFzf pipes lines into fzf with the given args and returns the selection.
// Returns empty string on no match. Exits the process on user cancel (Esc/Ctrl-C).
func runFzf(lines []string, args ...string) (string, error) {
	fzf := exec.Command("fzf", args...)
	fzf.Stderr = os.Stderr

	stdin, err := fzf.StdinPipe()
	if err != nil {
		return "", err
	}
	go func() {
		defer stdin.Close()
		for _, line := range lines {
			fmt.Fprintln(stdin, line)
		}
	}()

	output, err := fzf.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			switch exitErr.ExitCode() {
			case 130:
				os.Exit(0)
			case 1:
				return "", nil
			}
		}
		return "", err
	}

	return strings.TrimRight(string(output), "\n"), nil
}

// worktreeList emits branches not already checked out as a worktree,
// skipping remote branches when a local counterpart exists.
func worktreeList() error {
	info, err := fetchBranches(false, true)
	if err != nil {
		return err
	}

	for _, b := range info.branches {
		if _, ok := info.worktrees[b]; !ok {
			fmt.Println(b)
		}
	}
	return nil
}

// switchBranch runs an interactive fzf picker and outputs the git command to run.
func switchBranch() error {
	info, err := fetchBranches(false, true)
	if err != nil {
		return err
	}

	var lines []string
	for _, b := range info.branches {
		if wt, ok := info.worktrees[b]; ok {
			lines = append(lines, fmt.Sprintf("%s\t→ %s\t%s", b, filepath.Base(wt), wt))
		} else {
			lines = append(lines, fmt.Sprintf("%s\t\t", b))
		}
	}

	args := []string{
		"--delimiter=\t",
		"--with-nth=1,2",
		fmt.Sprintf("--preview=echo {}; git diff --color=always %s..{1} | %s", shellQuote(info.current), info.pager),
		"--preview-window=right,65%,border-none,wrap,~1",
	}
	args = append(args, os.Args[2:]...)

	selected, err := runFzf(lines, args...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	parts := strings.SplitN(selected, "\t", 3)
	branch := strings.TrimSpace(parts[0])
	worktreePath := ""
	if len(parts) == 3 {
		worktreePath = strings.TrimSpace(parts[2])
	}

	if worktreePath == "" {
		fmt.Printf("git checkout %s ", branch)
	} else {
		fmt.Printf("builtin cd '%s' ", worktreePath)
	}

	return nil
}

// mergeBranch picks a branch and outputs a git merge command.
func mergeBranch() error {
	info, err := fetchBranches(true, true)
	if err != nil {
		return err
	}

	args := []string{
		fmt.Sprintf("--header=merge into %s", info.current),
		"--bind=tab:down,btab:up",
		fmt.Sprintf("--preview=echo {}; git diff --color=always %s...{} | %s", shellQuote(info.current), info.pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	args = append(args, os.Args[2:]...)

	selected, err := runFzf(info.branches, args...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	fmt.Printf("git merge %s ", selected)
	return nil
}

// cherryPick picks a branch then commits from it, and outputs a git cherry-pick command.
func cherryPick() error {
	info, err := fetchBranches(true, true)
	if err != nil {
		return err
	}

	// Step 1: pick a branch.
	branchArgs := []string{
		fmt.Sprintf("--header=cherry-pick into %s", info.current),
		fmt.Sprintf("--preview=echo {}; git log --oneline --color=always {}"),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	branchArgs = append(branchArgs, os.Args[2:]...)

	branch, err := runFzf(info.branches, branchArgs...)
	if err != nil {
		return err
	}
	if branch == "" {
		return nil
	}

	// Step 2: pick commits from that branch that are not in HEAD.
	commits, err := gitLines("log", "--oneline", branch, "--not", "HEAD")
	if err != nil {
		return err
	}
	if len(commits) == 0 {
		return nil
	}

	commitArgs := []string{
		"--multi",
		"--bind=ctrl-a:select-all",
		fmt.Sprintf("--header=%s", branch),
		fmt.Sprintf("--preview=echo {}; git show --color=always --decorate {1} | %s", info.pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	commitArgs = append(commitArgs, os.Args[2:]...)

	selected, err := runFzf(commits, commitArgs...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	var hashes []string
	for _, line := range strings.Split(selected, "\n") {
		if fields := strings.Fields(line); len(fields) > 0 {
			hashes = append(hashes, fields[0])
		}
	}

	if len(hashes) > 0 {
		fmt.Printf("git cherry-pick %s", strings.Join(hashes, " "))
	}
	return nil
}

// diffBranches picks 1-2 branches, then files from their diff, and outputs an editor command.
func diffBranches() error {
	info, err := fetchBranches(false, false)
	if err != nil {
		return err
	}

	// Step 1: pick 1 or 2 branches.
	branchArgs := []string{
		"--multi",
		fmt.Sprintf("--preview=echo {}; git log --oneline --color=always {}"),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	branchArgs = append(branchArgs, os.Args[2:]...)

	selected, err := runFzf(info.branches, branchArgs...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	selectedBranches := strings.Split(selected, "\n")
	var branch1, branch2 string

	switch len(selectedBranches) {
	case 1:
		branch1 = selectedBranches[0]
		branch2 = info.current
	case 2:
		branch1 = selectedBranches[0]
		branch2 = selectedBranches[1]
	default:
		fmt.Fprintln(os.Stderr, "select 1 or 2 branches")
		return nil
	}

	// Step 2: pick files from the diff.
	files, err := gitLines("diff", "--name-only", branch1, branch2)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return nil
	}

	repoRoot, _ := gitLine("rev-parse", "--show-toplevel")
	cdup, _ := gitLine("rev-parse", "--show-cdup")

	fileArgs := []string{
		"--multi",
		"--bind=ctrl-a:select-all",
		fmt.Sprintf("--preview=echo {}; cd %s && git diff --color=always %s %s -- {} | %s",
			shellQuote(repoRoot), shellQuote(branch1), shellQuote(branch2), info.pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	fileArgs = append(fileArgs, os.Args[2:]...)

	selectedFiles, err := runFzf(files, fileArgs...)
	if err != nil {
		return err
	}
	if selectedFiles == "" {
		return nil
	}

	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}

	var quoted []string
	for _, f := range strings.Split(selectedFiles, "\n") {
		if f != "" {
			quoted = append(quoted, shellQuote(cdup+f))
		}
	}

	fmt.Printf("%s %s", editor, strings.Join(quoted, " "))
	return nil
}

// worktreeRemove picks worktrees to remove and outputs the shell commands to execute.
func worktreeRemove() error {
	var currentBranch, currentCommit string
	var wtLines []string
	var pager string
	var branchErr, commitErr, wtErr error

	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		currentBranch, branchErr = gitLine("rev-parse", "--abbrev-ref", "HEAD")
	}()
	go func() {
		defer wg.Done()
		currentCommit, commitErr = gitLine("rev-parse", "--short", "HEAD")
	}()
	go func() {
		defer wg.Done()
		wtLines, wtErr = gitLines("worktree", "list")
	}()
	go func() {
		defer wg.Done()
		pager = getPager()
	}()
	wg.Wait()

	if branchErr != nil {
		return branchErr
	}
	if commitErr != nil {
		return commitErr
	}
	if wtErr != nil {
		return wtErr
	}
	if len(wtLines) < 2 {
		return nil
	}

	mainWorktree := strings.Fields(wtLines[0])[0]
	currentDir, err := os.Getwd()
	if err != nil {
		return err
	}

	dirName := filepath.Base(currentDir)
	header := fmt.Sprintf("%s\t%s\t[%s]", dirName, currentCommit, currentBranch)

	// Parse non-main worktrees into tab-delimited display lines:
	//   dir \t commit \t [branch] \t fullpath
	var displayLines []string
	for _, line := range wtLines[1:] {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		wtPath := fields[0]
		commit := fields[1]
		branch := ""
		if start, end := strings.Index(line, "["), strings.Index(line, "]"); start != -1 && end != -1 {
			branch = line[start : end+1]
		}
		displayLines = append(displayLines,
			fmt.Sprintf("%s\t%s\t%s\t%s", filepath.Base(wtPath), commit, branch, wtPath))
	}
	if len(displayLines) == 0 {
		return nil
	}

	fzfArgs := []string{
		"--multi",
		"--bind=ctrl-a:select-all",
		fmt.Sprintf("--header=%s", header),
		"--with-nth=1,2,3",
		"--delimiter=\t",
		fmt.Sprintf("--preview=echo {1} {2} {3}; git diff --color=always %s..$(echo {3} | tr -d '[]') | %s",
			shellQuote(currentBranch), pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	fzfArgs = append(fzfArgs, os.Args[2:]...)

	selected, err := runFzf(displayLines, fzfArgs...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	var selectedPaths []string
	needsCd := false
	for _, line := range strings.Split(selected, "\n") {
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) < 4 {
			continue
		}
		p := parts[3]
		selectedPaths = append(selectedPaths, p)
		if p == currentDir {
			needsCd = true
		}
	}
	if len(selectedPaths) == 0 {
		return nil
	}

	var cmds []string
	if needsCd {
		cmds = append(cmds, fmt.Sprintf("builtin cd %s", shellQuote(mainWorktree)))
	}
	for _, p := range selectedPaths {
		cmds = append(cmds, fmt.Sprintf("git worktree remove %s", shellQuote(p)))
	}
	cmds = append(cmds, "ls")

	fmt.Print(strings.Join(cmds, " && "))
	return nil
}

// stashApply picks a stash then files from it, and outputs a git restore command.
func stashApply() error {
	var stashes []string
	var pager string
	var stashErr error

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		stashes, stashErr = gitLines("stash", "list")
	}()
	go func() {
		defer wg.Done()
		pager = getPager()
	}()
	wg.Wait()

	if stashErr != nil {
		return stashErr
	}
	if len(stashes) == 0 {
		return nil
	}

	// Step 1: pick a stash.
	stashArgs := []string{
		"--header=select stash to apply",
		"--delimiter=:",
		fmt.Sprintf("--preview=echo {}; git stash show --color=always {1} | %s", pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	stashArgs = append(stashArgs, os.Args[2:]...)

	selectedStash, err := runFzf(stashes, stashArgs...)
	if err != nil {
		return err
	}
	if selectedStash == "" {
		return nil
	}

	stashName := strings.SplitN(selectedStash, ":", 2)[0]

	stashRef, err := gitLine("rev-parse", stashName)
	if err != nil {
		return err
	}

	// Step 2: pick files from that stash.
	files, err := gitLines("stash", "show", "--name-only", stashRef)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return nil
	}

	fileArgs := []string{
		"--multi",
		"--bind=ctrl-a:select-all",
		"--header=select files to apply (ctrl-a: all)",
		fmt.Sprintf("--preview=echo {}; git diff --color=always %s^ %s -- {} | %s", stashRef, stashRef, pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	fileArgs = append(fileArgs, os.Args[2:]...)

	selectedFiles, err := runFzf(files, fileArgs...)
	if err != nil {
		return err
	}
	if selectedFiles == "" {
		return nil
	}

	var quoted []string
	for _, f := range strings.Split(selectedFiles, "\n") {
		if f != "" {
			quoted = append(quoted, shellQuote(f))
		}
	}

	fmt.Printf("git restore --source=%s -- %s && git status", stashName, strings.Join(quoted, " "))
	return nil
}
