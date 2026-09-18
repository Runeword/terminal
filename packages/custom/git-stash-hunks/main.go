// Command git-stash-hunks turns a selected subset of *working-tree* changes into
// one real git stash entry without touching the index, then removes those
// changes from the working tree. It is the plumbing behind the two-level `gsp`
// picker (see __git_pick_files in sources/.config/shell/functions/git.bash).
//
// Input is the selection from that picker:
//   - stdin: a unified diff of the drilled hunks (git-hunk-pick assemble output),
//     possibly empty;
//   - --whole <path> (repeatable): whole files chosen with Tab. The bin decides
//     per file whether it is tracked (its `git diff --unified=0` is folded into
//     the captured patch) or untracked (added to the stash tree as a new file).
//
// It mirrors what `git stash create` does internally: the stash's worktree tree
// is built in a TEMPORARY index seeded from HEAD (GIT_INDEX_FILE), so the real
// index / staged changes are never read or written; the stash is the usual
// two-parent commit (base = HEAD, index = HEAD) stored via `git stash store`.
// The captured changes are then reverse-applied out of the working tree (and
// untracked files removed), so `git stash pop` re-applies exactly them.
//
// Scope: because a coherent per-hunk stash can only come from the working tree,
// this stashes UNSTAGED changes only; anything staged is left staged.
//
// Usage:  <hunk patch on stdin> | git-stash-hunks [-m message] [--whole path]...
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

func main() {
	msg := "WIP: partial stash (git-stash-hunks)"
	var whole []string
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-m", "--message":
			i++
			if i >= len(args) {
				fatal("missing value for " + args[i-1])
			}
			msg = args[i]
		case "--whole":
			i++
			if i >= len(args) {
				fatal("missing value for --whole")
			}
			whole = append(whole, args[i])
		default:
			fatal("unknown argument: " + args[i])
		}
	}
	hunks, err := io.ReadAll(os.Stdin)
	if err != nil {
		fatal("reading hunk patch from stdin: " + err.Error())
	}
	if err := run(hunks, whole, msg); err != nil {
		fatal(err.Error())
	}
}

func fatal(m string) {
	fmt.Fprintln(os.Stderr, "git-stash-hunks: "+m)
	os.Exit(1)
}

// git runs a git command with extra env and optional stdin, returning raw
// stdout. A non-zero exit becomes an error carrying git's stderr.
func git(env []string, stdin []byte, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Env = append(os.Environ(), env...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// line runs git and returns trimmed single-line stdout (for SHAs/paths).
func line(env []string, args ...string) (string, error) {
	out, err := git(env, nil, args...)
	return strings.TrimSpace(string(out)), err
}

func run(hunks []byte, whole []string, msg string) error {
	// Resolve everything from the repo toplevel so that toplevel-relative paths
	// (what the picker passes) and the diff paths agree regardless of the cwd the
	// echoed command runs from.
	top, err := line(nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return err
	}
	if err := os.Chdir(top); err != nil {
		return err
	}
	if _, err := line(nil, "rev-parse", "--verify", "HEAD"); err != nil {
		return fmt.Errorf("no commit yet (unborn HEAD); nothing to stash against")
	}

	// Fold each tracked whole file's diff into the captured patch; collect the
	// untracked ones to add as new files.
	captured := append([]byte(nil), hunks...)
	var untracked []string
	for _, w := range whole {
		if _, err := git(nil, nil, "ls-files", "--error-unmatch", "--", w); err != nil {
			untracked = append(untracked, w)
			continue
		}
		d, err := git(nil, nil, "diff", "--unified=0", "--", w)
		if err != nil {
			return err
		}
		captured = append(captured, d...)
	}
	hasPatch := len(bytes.TrimSpace(captured)) > 0
	if !hasPatch && len(untracked) == 0 {
		return nil // nothing selected
	}

	// Identity for the plumbing commits: respect env/config when present, else a
	// stash default so this works with no user.name configured (bare repo, CI,
	// tests). git var errors when no identity resolves.
	var ident []string
	if err := exec.Command("git", "var", "GIT_COMMITTER_IDENT").Run(); err != nil {
		ident = []string{
			"GIT_AUTHOR_NAME=git-stash-hunks", "GIT_AUTHOR_EMAIL=git-stash-hunks@localhost",
			"GIT_COMMITTER_NAME=git-stash-hunks", "GIT_COMMITTER_EMAIL=git-stash-hunks@localhost",
		}
	}

	tmp, err := os.CreateTemp("", "git-stash-hunks-index-*")
	if err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	idxEnv := append([]string{"GIT_INDEX_FILE=" + tmp.Name()}, ident...)

	// Build the stash's worktree tree in the temp index: HEAD + captured changes.
	// The real index is never read or written.
	if _, err := git(idxEnv, nil, "read-tree", "HEAD"); err != nil {
		return err
	}
	if hasPatch {
		if _, err := git(idxEnv, captured, "apply", "--cached", "--unidiff-zero", "--recount"); err != nil {
			return fmt.Errorf("applying the picked changes to the stash tree: %w", err)
		}
	}
	for _, u := range untracked {
		if _, err := git(idxEnv, nil, "add", "--", u); err != nil {
			return err
		}
	}
	wtree, err := line(idxEnv, "write-tree")
	if err != nil {
		return err
	}

	// Two-parent stash commit; index tree = HEAD, so nothing staged is recorded.
	head, err := line(ident, "rev-parse", "HEAD")
	if err != nil {
		return err
	}
	htree, err := line(ident, "rev-parse", "HEAD^{tree}")
	if err != nil {
		return err
	}
	icommit, err := line(ident, "commit-tree", htree, "-p", head, "-m", "index on "+msg)
	if err != nil {
		return err
	}
	wcommit, err := line(ident, "commit-tree", wtree, "-p", head, "-p", icommit, "-m", msg)
	if err != nil {
		return err
	}

	// Register the stash first — once stored the change is safely captured; only
	// then mutate the working tree (a failure here means: drop the stash and
	// retry, never lose the change).
	if _, err := git(ident, nil, "stash", "store", "-m", msg, wcommit); err != nil {
		return err
	}
	if hasPatch {
		if _, err := git(nil, captured, "apply", "--reverse", "--unidiff-zero", "--recount"); err != nil {
			return fmt.Errorf("stash saved, but removing the changes from the working tree failed (drop the stash and retry): %w", err)
		}
	}
	for _, u := range untracked {
		if err := os.Remove(u); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("stash saved, but removing untracked %q failed: %w", u, err)
		}
	}
	return nil
}
