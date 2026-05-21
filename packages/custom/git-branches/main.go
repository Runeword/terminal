package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// errFzfCancel signals that the user dismissed fzf (Esc / Ctrl-C). main()
// translates it to a clean exit so deferred cleanup in callers still runs.
var errFzfCancel = errors.New("fzf canceled")

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: git-branches <worktree|worktree-add|switch|merge|cherry-pick|diff-branches|worktree-remove|stash-apply>")
		os.Exit(1)
	}

	// Every subcommand needs a work tree. Exit silently when invoked outside
	// one so leader-key chords stay quiet in unrelated directories.
	if err := exec.Command("git", "rev-parse", "--is-inside-work-tree").Run(); err != nil {
		return
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
	case "worktree-add":
		err = worktreeAdd()
	case "worktree-remove":
		err = worktreeRemove()
	case "stash-apply":
		err = stashApply()
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		os.Exit(1)
	}

	if err != nil {
		if errors.Is(err, errFzfCancel) {
			return
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// runGit invokes git and returns its stdout. On a non-zero exit, the returned
// error includes git's stderr instead of the opaque "exit status N" that
// *exec.ExitError formats to by default.
func runGit(args ...string) ([]byte, error) {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && len(exitErr.Stderr) > 0 {
			return out, fmt.Errorf("git %s: %s", strings.Join(args, " "), strings.TrimSpace(string(exitErr.Stderr)))
		}
		return out, err
	}
	return out, nil
}

func gitLines(args ...string) ([]string, error) {
	out, err := runGit(args...)
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
	out, err := runGit(args...)
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

type worktree struct {
	path     string
	head     string // full sha
	branch   string // refs/heads/foo, "" if detached or bare
	detached bool
	bare     bool
	locked   bool
}

// listWorktrees parses `git worktree list --porcelain`. The first entry is the
// main worktree. Robust against paths with spaces and detached/bare/locked
// worktrees, unlike the plain whitespace-delimited format.
func listWorktrees() ([]worktree, error) {
	out, err := runGit("worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	var worktrees []worktree
	var cur *worktree
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			if cur != nil {
				worktrees = append(worktrees, *cur)
				cur = nil
			}
			continue
		}
		if cur == nil {
			cur = &worktree{}
		}
		switch {
		case strings.HasPrefix(line, "worktree "):
			cur.path = line[len("worktree "):]
		case strings.HasPrefix(line, "HEAD "):
			cur.head = line[len("HEAD "):]
		case strings.HasPrefix(line, "branch "):
			cur.branch = line[len("branch "):]
		case line == "detached":
			cur.detached = true
		case line == "bare":
			cur.bare = true
		case line == "locked", strings.HasPrefix(line, "locked "):
			cur.locked = true
		}
	}
	if cur != nil {
		worktrees = append(worktrees, *cur)
	}
	return worktrees, nil
}

type branchInfo struct {
	current   string // attached: short branch name; detached: short commit sha
	detached  bool
	branches  []string
	worktrees map[string]string // branch → worktree path
	pager     string
}

// detectHead returns the short branch name when HEAD points at a branch, or
// the abbreviated commit sha when HEAD is detached. The bool is true iff
// detached. Using `symbolic-ref -q --short` (quiet on failure) avoids the
// `git rev-parse --abbrev-ref HEAD` quirk that returns the literal string
// "HEAD" in detached mode — which then poisons every header and diff range
// that interpolates it.
func detectHead() (string, bool, error) {
	if name, err := gitLine("symbolic-ref", "-q", "--short", "HEAD"); err == nil && name != "" {
		return name, false, nil
	}
	sha, err := gitLine("rev-parse", "--short", "HEAD")
	if err != nil {
		return "", false, err
	}
	return sha, true, nil
}

// fetchBranches concurrently fetches the current branch, the local and
// remote-tracking branches (with their worktree paths), the list of configured
// remotes, and the pager. Locals and remotes are queried separately via
// for-each-ref so a local branch like `feature/foo` is never mistaken for a
// `feature/foo` remote-tracking ref. When dedupRemote is true, a remote-
// tracking branch is hidden iff a local branch with the same logical name
// exists; "logical name" is computed by stripping a known remote prefix
// (longest match wins, so a remote literally named `origin/mirror` is handled
// before falling back to `origin`).
func fetchBranches(excludeCurrent, dedupRemote bool) (*branchInfo, error) {
	var current, pager string
	var detached bool
	var refRaw, remotes []string
	var currentErr, refErr error

	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		current, detached, currentErr = detectHead()
	}()
	go func() {
		defer wg.Done()
		refRaw, refErr = gitLines("for-each-ref",
			"--format=%(refname)%09%(worktreepath)%09%(symref)",
			"refs/heads", "refs/remotes")
	}()
	go func() {
		defer wg.Done()
		// A repo can legitimately have zero remotes; ignore errors.
		remotes, _ = gitLines("remote")
	}()
	go func() {
		defer wg.Done()
		pager = getPager()
	}()
	wg.Wait()

	if currentErr != nil {
		return nil, currentErr
	}
	if refErr != nil {
		return nil, refErr
	}

	localSet := map[string]bool{}
	worktrees := map[string]string{}
	var locals []string

	type remoteBranch struct {
		display string // e.g. "origin/main" or "upstream/feature/foo"
		logical string // e.g. "main" or "feature/foo" — used for dedupe vs local
	}
	var remoteList []remoteBranch

	for _, line := range refRaw {
		parts := strings.SplitN(line, "\t", 3)
		ref := parts[0]
		var worktreePath, symref string
		if len(parts) >= 2 {
			worktreePath = parts[1]
		}
		if len(parts) >= 3 {
			symref = parts[2]
		}
		if ref == "" || symref != "" {
			continue
		}
		switch {
		case strings.HasPrefix(ref, "refs/heads/"):
			name := strings.TrimPrefix(ref, "refs/heads/")
			localSet[name] = true
			locals = append(locals, name)
			if worktreePath != "" {
				worktrees[name] = worktreePath
			}
		case strings.HasPrefix(ref, "refs/remotes/"):
			short := strings.TrimPrefix(ref, "refs/remotes/")
			bestRemote := ""
			for _, r := range remotes {
				if r != "" && strings.HasPrefix(short, r+"/") && len(r) > len(bestRemote) {
					bestRemote = r
				}
			}
			logical := short
			if bestRemote != "" {
				logical = short[len(bestRemote)+1:]
			}
			remoteList = append(remoteList, remoteBranch{display: short, logical: logical})
		}
	}

	var all []string
	for _, name := range locals {
		if excludeCurrent && name == current {
			continue
		}
		all = append(all, name)
	}
	for _, rb := range remoteList {
		if dedupRemote && localSet[rb.logical] {
			continue
		}
		all = append(all, rb.display)
	}

	return &branchInfo{
		current:   current,
		detached:  detached,
		branches:  all,
		worktrees: worktrees,
		pager:     pager,
	}, nil
}

// runFzf pipes lines into fzf with the given args and returns the selection.
// Returns "" on no match, and errFzfCancel when the user dismisses fzf
// (Esc/Ctrl-C) so callers can unwind cleanly.
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
				return "", errFzfCancel
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
		fmt.Sprintf("--preview=echo {}; git diff --color=always --end-of-options %s..{1} | %s", shellQuote(info.current), info.pager),
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
		fmt.Printf("git checkout --end-of-options %s ", shellQuote(branch))
	} else {
		fmt.Printf("builtin cd %s ", shellQuote(worktreePath))
	}

	return nil
}

// mergeBranch picks a branch and outputs a git merge command.
func mergeBranch() error {
	info, err := fetchBranches(true, true)
	if err != nil {
		return err
	}
	if info.detached {
		return fmt.Errorf("merge: HEAD is detached (at %s); check out a branch first", info.current)
	}

	args := []string{
		fmt.Sprintf("--header=merge into %s", info.current),
		"--bind=tab:down,btab:up",
		fmt.Sprintf("--preview=echo {}; git diff --color=always --end-of-options %s...{} | %s", shellQuote(info.current), info.pager),
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

	fmt.Printf("git merge --end-of-options %s ", shellQuote(selected))
	return nil
}

// cherryPick picks a branch then commits from it, and outputs a git cherry-pick command.
func cherryPick() error {
	info, err := fetchBranches(true, true)
	if err != nil {
		return err
	}
	if info.detached {
		return fmt.Errorf("cherry-pick: HEAD is detached (at %s); check out a branch first", info.current)
	}

	// Step 1: pick a branch.
	branchArgs := []string{
		fmt.Sprintf("--header=cherry-pick into %s", info.current),
		fmt.Sprintf("--preview=echo {}; git log --oneline --color=always --end-of-options {}"),
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
		quoted := make([]string, len(hashes))
		for i, h := range hashes {
			quoted[i] = shellQuote(h)
		}
		fmt.Printf("git cherry-pick %s", strings.Join(quoted, " "))
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
		fmt.Sprintf("--preview=echo {}; git log --oneline --color=always --end-of-options {}"),
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
		fmt.Sprintf("--preview=echo {}; cd %s && git diff --color=always --end-of-options %s %s -- {} | %s",
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

func worktreeAdd() error {
	var info *branchInfo
	var currentCommit string
	var worktrees []worktree
	var infoErr, commitErr, wtErr error

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		info, infoErr = fetchBranches(false, true)
	}()
	go func() {
		defer wg.Done()
		currentCommit, commitErr = gitLine("rev-parse", "--short", "HEAD")
	}()
	go func() {
		defer wg.Done()
		worktrees, wtErr = listWorktrees()
	}()
	wg.Wait()

	if infoErr != nil {
		return infoErr
	}
	if commitErr != nil {
		return commitErr
	}
	if wtErr != nil {
		return wtErr
	}
	if len(worktrees) == 0 {
		return nil
	}

	var available []string
	for _, b := range info.branches {
		if _, ok := info.worktrees[b]; !ok {
			available = append(available, b)
		}
	}
	if len(available) == 0 {
		return nil
	}

	currentDir, err := os.Getwd()
	if err != nil {
		return err
	}
	branchLabel := "[" + info.current + "]"
	if info.detached {
		branchLabel = "(detached)"
	}
	header := fmt.Sprintf("%s\t%s\t%s", filepath.Base(currentDir), currentCommit, branchLabel)

	fzfArgs := []string{
		fmt.Sprintf("--header=%s", header),
		fmt.Sprintf("--preview=echo {}; git diff --color=always --end-of-options %s..{} | %s",
			shellQuote(info.current), info.pager),
		"--preview-window=right,75%,border-none,wrap,~1",
	}
	fzfArgs = append(fzfArgs, os.Args[2:]...)

	selected, err := runFzf(available, fzfArgs...)
	if err != nil {
		return err
	}
	if selected == "" {
		return nil
	}

	// Pick a fresh sibling-of-main-worktree directory name. Anchoring to the
	// main worktree (rather than CWD) means `gwa` invoked from inside an
	// existing sibling worktree still proposes the right slot — using `..` from
	// CWD would otherwise resolve to a different parent and could collide with
	// the main checkout or an unrelated directory.
	baseDir := filepath.Dir(worktrees[0].path)
	repoName := filepath.Base(worktrees[0].path)
	const maxAttempts = 1000
	var worktreePath string
	for n := 1; n <= maxAttempts; n++ {
		candidate := filepath.Join(baseDir, fmt.Sprintf("%s_%d", repoName, n))
		_, err := os.Stat(candidate)
		if errors.Is(err, fs.ErrNotExist) {
			worktreePath = candidate
			break
		}
		// Any other state (exists as dir/file/symlink, EACCES, EIO, ...) means
		// we can't safely use this name. Skip rather than breaking the loop,
		// which would have reused a directory that happened to be unreadable.
	}
	if worktreePath == "" {
		return fmt.Errorf("worktree-add: no free directory name under %s within %d tries", baseDir, maxAttempts)
	}

	fmt.Printf("git worktree add --end-of-options %s %s && builtin cd %s ",
		shellQuote(worktreePath), shellQuote(selected), shellQuote(worktreePath))
	return nil
}

// worktreeRemove picks worktrees to remove and outputs the shell commands to execute.
func worktreeRemove() error {
	var currentBranch, currentCommit string
	var detached bool
	var worktrees []worktree
	var pager string
	var branchErr, commitErr, wtErr error

	var wg sync.WaitGroup
	wg.Add(4)
	go func() {
		defer wg.Done()
		currentBranch, detached, branchErr = detectHead()
	}()
	go func() {
		defer wg.Done()
		currentCommit, commitErr = gitLine("rev-parse", "--short", "HEAD")
	}()
	go func() {
		defer wg.Done()
		worktrees, wtErr = listWorktrees()
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
	if len(worktrees) < 2 {
		return nil
	}

	mainWorktree := worktrees[0].path
	currentDir, err := os.Getwd()
	if err != nil {
		return err
	}

	dirName := filepath.Base(currentDir)
	branchLabel := "[" + currentBranch + "]"
	if detached {
		branchLabel = "(detached)"
	}
	header := fmt.Sprintf("%s\t%s\t%s", dirName, currentCommit, branchLabel)

	// Tab-delimited display lines for fzf:
	//   dir \t commit \t [branch] \t fullpath \t shell-quoted diff target
	// Columns 1-3 are shown; column 4 is the path used for removal; column 5
	// is a pre-quoted ref (branch name or sha for detached) used in --preview.
	var displayLines []string
	for _, wt := range worktrees[1:] {
		if wt.bare {
			continue
		}
		short := wt.head
		if len(short) > 7 {
			short = short[:7]
		}
		var displayBranch, diffTarget string
		if wt.detached || wt.branch == "" {
			displayBranch = "(detached)"
			diffTarget = wt.head
		} else {
			name := strings.TrimPrefix(wt.branch, "refs/heads/")
			displayBranch = "[" + name + "]"
			diffTarget = name
		}
		displayLines = append(displayLines,
			fmt.Sprintf("%s\t%s\t%s\t%s\t%s",
				filepath.Base(wt.path), short, displayBranch, wt.path, shellQuote(diffTarget)))
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
		fmt.Sprintf("--preview=echo {1} {2} {3}; git diff --color=always --end-of-options %s..{5} | %s",
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
		parts := strings.SplitN(line, "\t", 5)
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

	// Use the resolved sha (not stash@{N}) so the command stays correct even if
	// another stash is pushed/popped between selection and execution — stash
	// reflog indices shift, but the sha doesn't move.
	fmt.Printf("git restore --source=%s -- %s && git status", shellQuote(stashRef), strings.Join(quoted, " "))
	return nil
}
