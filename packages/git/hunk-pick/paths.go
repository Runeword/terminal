package main

// The other file pickers in .config/shell/functions/git.bash (commit, diff,
// untrack, clean and ignore through __git_fzf_select, and the file steps of
// the log and diff-revs pickers) each pick from one kind of path list (see
// pathKinds): paths prints it NUL-separated for fzf --read0, and quote turns
// fzf's --print0 selection into the shell words of the command the picker
// prints. No line-based tool sits in between, so a name git would quote
// (café.txt under the default core.quotePath, a tab or newline in it, a space
// in a status line) reaches the printed command as is.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
)

// The git commands behind the changed-files lists, which the file picker
// (files) shares: their -z outputs are verbatim paths relative to the repo
// root.
var (
	gitStaged    = []string{"diff", "--cached", "--name-only", "-z"}
	gitModified  = []string{"diff", "--name-only", "-z"}
	gitUntracked = []string{"ls-files", "--others", "--exclude-standard", "-z"}
)

// pathKind is one list a picker chooses from: the paths in its git commands'
// outputs, run from the repo root.
type pathKind struct {
	cmds  [][]string
	parse func(string) []string // splits one output; nil for a -z list
	rev   bool                  // takes a revision, appended to its one command
}

var pathKinds = map[string]pathKind{
	"staged": {cmds: [][]string{gitStaged}},
	// What git add takes: unstaged changes and untracked files.
	"unstaged": {cmds: [][]string{gitModified, gitUntracked}},
	"changed":  {cmds: [][]string{gitStaged, gitModified, gitUntracked}},
	// What git clean -d removes: an untracked directory as one dir/ entry, or
	// file by file when it holds ignored files, which clean keeps.
	"untracked": {cmds: [][]string{{"clean", "--dry-run", "-d"}}, parse: cleanList},
	// Ignored files, an ignored directory as one dir/ entry.
	"ignored": {cmds: [][]string{{"ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"}}},
	// The files a commit changed.
	"commit": {cmds: [][]string{{"diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z"}}, rev: true},
	// Every file in a revision: the whole tree, from any directory.
	"tree": {cmds: [][]string{{"ls-tree", "-r", "--full-tree", "--name-only", "-z"}}, rev: true},
}

// cleanList returns the paths in git clean's dry run, its "Would remove PATH"
// lines (in English: runPaths sets LC_ALL=C). It has no -z, so a path git
// can't print raw comes C-quoted ("caf\303\251.txt"), which this undoes; a
// path it can stays raw, spaces included.
func cleanList(out string) []string {
	var paths []string
	for _, line := range strings.Split(out, "\n") {
		p, ok := strings.CutPrefix(line, "Would remove ")
		if !ok {
			continue
		}
		if strings.HasPrefix(p, `"`) {
			if u, err := strconv.Unquote(p); err == nil {
				p = u
			}
		}
		paths = append(paths, p)
	}
	return paths
}

// gitList runs each git command and returns the paths in their outputs, split
// by parse, sorted and without duplicates.
func gitList(git func(args ...string) (string, error), cmds [][]string, parse func(string) []string) ([]string, error) {
	var names []string
	for _, args := range cmds {
		out, err := git(args...)
		if err != nil {
			return nil, err
		}
		names = append(names, parse(out)...)
	}
	slices.Sort(names)
	return slices.Compact(names), nil
}

// listPaths returns the list of the kind called name; rev is the revision a
// commit or tree kind takes, and empty for the others.
func listPaths(git func(args ...string) (string, error), name, rev string) ([]string, error) {
	kind, ok := pathKinds[name]
	if !ok {
		return nil, fmt.Errorf("unknown kind %q: staged, unstaged, changed, untracked, ignored, commit or tree", name)
	}
	if kind.rev != (rev != "") {
		if kind.rev {
			return nil, fmt.Errorf("%s takes a revision", name)
		}
		return nil, fmt.Errorf("%s takes no revision", name)
	}
	cmds := kind.cmds
	if kind.rev {
		cmds = [][]string{slices.Concat(kind.cmds[0], []string{"--end-of-options", rev})}
	}
	parse := kind.parse
	if parse == nil {
		parse = splitList
	}
	return gitList(git, cmds, parse)
}

// quote returns the entries of the NUL-separated list on r (fzf's --print0
// selection), each prefixed with prefix and shell-quoted, joined by spaces.
// prefix is a cd-up path (git rev-parse --show-cdup) when the printed command
// runs from the caller's directory, not the repo root.
func quote(r io.Reader, prefix string) (string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	entries := splitList(string(data))
	words := make([]string, len(entries))
	for i, e := range entries {
		words[i] = shellQuote(prefix + e)
	}
	return strings.Join(words, " "), nil
}

// runPaths dispatches paths, which writes a kind's list NUL-separated for fzf
// --read0, and quote, which reads the selection on r and writes its words.
func runPaths(cmd string, args []string, r io.Reader, w io.Writer) error {
	var out string
	switch cmd {
	case "paths":
		if len(args) < 1 || len(args) > 2 {
			return errors.New("usage: git-hunk-pick paths KIND [REV]")
		}
		// cleanList reads git clean's messages.
		if err := os.Setenv("LC_ALL", "C"); err != nil {
			return err
		}
		rev := ""
		if len(args) == 2 {
			rev = args[1]
		}
		names, err := listPaths(runGit, args[0], rev)
		if err != nil {
			return err
		}
		out = joinList(names)
	case "quote":
		if len(args) > 1 {
			return errors.New("usage: git-hunk-pick quote [PREFIX]  (the selection on stdin)")
		}
		prefix := ""
		if len(args) == 1 {
			prefix = args[0]
		}
		words, err := quote(r, prefix)
		if err != nil {
			return err
		}
		if words != "" {
			out = words + "\n"
		}
	}
	_, err := io.WriteString(w, out)
	return err
}
