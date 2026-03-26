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
		fmt.Fprintln(os.Stderr, "usage: git-branches <worktree|switch>")
		os.Exit(1)
	}

	var err error
	switch os.Args[1] {
	case "worktree":
		err = worktreeList()
	case "switch":
		err = switchBranch()
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

// worktreeList emits branches not already checked out as a worktree,
// skipping remote branches when a local counterpart exists.
func worktreeList() error {
	var branches, worktrees []string
	var branchErr, worktreeErr error

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); branches, branchErr = gitLines("branch", "--all", "--format=%(refname:short)") }()
	go func() { defer wg.Done(); worktrees, worktreeErr = gitLines("worktree", "list") }()
	wg.Wait()

	if branchErr != nil {
		return branchErr
	}
	if worktreeErr != nil {
		return worktreeErr
	}

	// Parse checked-out branch names from "git worktree list".
	// Lines look like: /path/to/wt  abc1234  [branch]
	checkedOut := map[string]bool{}
	for _, line := range worktrees {
		start := strings.Index(line, "[")
		end := strings.Index(line, "]")
		if start != -1 && end != -1 {
			checkedOut[line[start+1:end]] = true
		}
	}

	// First pass: collect all local branch names (no slash).
	local := map[string]bool{}
	var all []string
	for _, b := range branches {
		if b == "" || strings.HasPrefix(b, "HEAD") {
			continue
		}
		if !strings.Contains(b, "/") {
			local[b] = true
		}
		all = append(all, b)
	}

	// Second pass: emit branches passing both filters.
	for _, b := range all {
		if checkedOut[b] {
			continue
		}
		if idx := strings.Index(b, "/"); idx != -1 {
			if local[b[idx+1:]] {
				continue
			}
		}
		fmt.Println(b)
	}
	return nil
}

// switchBranch runs an interactive fzf picker and outputs the git command to run.
func switchBranch() error {
	var currentBranch string
	var raw []string
	var currentErr, rawErr error

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		currentBranch, currentErr = gitLine("rev-parse", "--abbrev-ref", "HEAD")
	}()
	go func() {
		defer wg.Done()
		raw, rawErr = gitLines("branch", "--all",
			"--format=%(HEAD)%(refname:short)%09%(worktreepath)%09%(symref)")
	}()
	wg.Wait()

	if currentErr != nil {
		return currentErr
	}
	if rawErr != nil {
		return rawErr
	}

	pager, _ := gitLine("config", "core.pager")
	if pager == "" {
		pager = "cat"
	}

	type entry struct {
		branch   string
		worktree string
	}

	local := map[string]bool{}
	var entries []entry

	for _, line := range raw {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		branch := strings.TrimLeft(parts[0], "* ")
		wt := parts[1]
		symref := parts[2]

		if branch == "" || strings.HasPrefix(branch, "HEAD") || symref != "" {
			continue
		}
		if !strings.Contains(branch, "/") {
			local[branch] = true
		}
		entries = append(entries, entry{branch, wt})
	}

	var lines []string
	for _, e := range entries {
		if idx := strings.Index(e.branch, "/"); idx != -1 {
			if local[e.branch[idx+1:]] {
				continue
			}
		}
		if e.worktree != "" {
			lines = append(lines, fmt.Sprintf("%s\t→ %s\t%s", e.branch, filepath.Base(e.worktree), e.worktree))
		} else {
			lines = append(lines, fmt.Sprintf("%s\t\t", e.branch))
		}
	}

	fzfArgs := []string{
		"--delimiter=\t",
		"--with-nth=1,2",
		fmt.Sprintf("--preview=echo {}; git diff --color=always %s..{1} | %s", currentBranch, pager),
		"--preview-window=right,65%,border-none,wrap,~1",
	}
	fzfArgs = append(fzfArgs, os.Args[2:]...)
	fzf := exec.Command("fzf", fzfArgs...)
	fzf.Stderr = os.Stderr

	fzfStdin, err := fzf.StdinPipe()
	if err != nil {
		return err
	}
	go func() {
		defer fzfStdin.Close()
		for _, line := range lines {
			fmt.Fprintln(fzfStdin, line)
		}
	}()

	output, err := fzf.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			if exitErr.ExitCode() == 130 {
				os.Exit(0)
			}
			if exitErr.ExitCode() == 1 {
				return nil
			}
		}
		return err
	}

	selected := strings.TrimRight(string(output), "\n")
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
