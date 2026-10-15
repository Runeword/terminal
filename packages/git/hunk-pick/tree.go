package main

// The log picker's file step (__git_log in .config/shell/functions/git.bash)
// shows a commit's files as a tree: tree prints one fzf row per directory and
// file of a revision's list, and tree-quote turns the rows fzf accepts back
// into the shell words of the command the picker prints.
//
// A row is two fields separated by 0x1f, NUL-terminated for fzf --read0:
//
//	TREE 0x1f PATH
//
// TREE draws the row in the tree, which is all fzf shows and searches; a
// directory's ends in "/", a file's never does. PATH is what the preview
// shows: the file, or the directory with a trailing slash, which git reads as
// every file below it. A directory whose only entry is a directory shares its
// row (git/hunk-pick/, as lazygit's tree does). A directory's row is the
// tree's structure, not a pick: the picker keeps it out of its matches, and
// tree-quote drops it.
//
// fzf hands back the accepted rows' indices (--accept-nth '{n}'), not their
// text: TREE carries colour escapes (--ansi), and a name may hold any byte but
// NUL. tree-quote lists the revision again to map them, which is exact
// because a revision's list can't change in between: tree takes the commit
// and tree kinds only.

import (
	"errors"
	"fmt"
	"io"
	"slices"
	"strconv"
	"strings"
	"unicode"
)

// The tree's colours: its lines in the border colour of the pickers' fzf, a
// directory in ls's (dircolors' di=01;34).
const (
	treeLineColor = "\x1b[38;2;47;57;74m"
	treeDirColor  = "\x1b[1;34m"
	colorReset    = "\x1b[0m"
)

// treeRow is one row of the tree: a directory or a file.
type treeRow struct {
	lines string // the tree's lines before the name: "│ ├╴"
	name  string // the file's name, or the directory's with "/", merged ones included: "git/hunk-pick/"
	path  string // the file's path, or the directory's with "/", from the repo root
}

func (r treeRow) isDir() bool { return strings.HasSuffix(r.path, "/") }

// dirNode is one directory of a list: its subdirectories by name, and the
// paths of its files in list order.
type dirNode struct {
	dirs  map[string]*dirNode
	files []string
}

// treeRows lays out the paths of a list (sorted, as listPaths returns them)
// as a tree, depth first, each directory's subdirectories before its files.
// The top level's entries have no lines of their own.
func treeRows(paths []string) []treeRow {
	root := &dirNode{}
	for _, p := range paths {
		n := root
		parts := strings.Split(p, "/")
		for _, d := range parts[:len(parts)-1] {
			if n.dirs[d] == nil {
				if n.dirs == nil {
					n.dirs = map[string]*dirNode{}
				}
				n.dirs[d] = &dirNode{}
			}
			n = n.dirs[d]
		}
		n.files = append(n.files, p)
	}

	var rows []treeRow
	var walk func(n *dirNode, dir, lines string, top bool)
	walk = func(n *dirNode, dir, lines string, top bool) {
		names := make([]string, 0, len(n.dirs))
		for name := range n.dirs {
			names = append(names, name)
		}
		slices.Sort(names)
		last := len(names) + len(n.files) - 1
		for i := 0; i <= last; i++ {
			branch, below := "├╴", "│ "
			if i == last {
				branch, below = "└╴", "  "
			}
			if top {
				branch, below = "", ""
			}
			if i >= len(names) {
				p := n.files[i-len(names)]
				rows = append(rows, treeRow{lines + branch, p[len(dir):], p})
				continue
			}
			name, sub := names[i]+"/", n.dirs[names[i]]
			for len(sub.dirs) == 1 && len(sub.files) == 0 {
				for only, d := range sub.dirs {
					name, sub = name+only+"/", d
				}
			}
			rows = append(rows, treeRow{lines + branch, name, dir + name})
			walk(sub, dir+name, lines+below, false)
		}
	}
	walk(root, "", "", true)
	return rows
}

// visible replaces the control characters in a name with ones that show: a
// C0 control with its Control Pictures symbol (a newline with ␊), DEL with ␡
// and a C1 control with U+FFFD. So a row stays one line, a 0x1f can't end its
// first field, and no name sends the terminal an escape.
func visible(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r < 0x20:
			return 0x2400 + r
		case r == 0x7f:
			return '␡'
		case unicode.IsControl(r):
			return unicode.ReplacementChar
		}
		return r
	}, s)
}

// record is the row as the picker's fzf reads it (see the top of the file).
func (r treeRow) record() string {
	var tree string
	if r.lines != "" {
		tree = treeLineColor + r.lines + colorReset
	}
	if r.isDir() {
		tree += treeDirColor + visible(r.name) + colorReset
	} else {
		tree += visible(r.name)
	}
	return tree + "\x1f" + r.path + "\x00"
}

// treeList returns the tree rows of the list of kind for rev, which must be a
// revision's list (see the top of the file).
func treeList(git func(args ...string) (string, error), kind, rev string) ([]treeRow, error) {
	if k, ok := pathKinds[kind]; ok && !k.rev {
		return nil, fmt.Errorf("tree lists a revision's files (commit or tree), not %s", kind)
	}
	paths, err := listPaths(git, kind, rev)
	if err != nil {
		return nil, err
	}
	return treeRows(paths), nil
}

// treeQuote returns the shell words of the files among the rows whose indices
// are on r (fzf's --print0 output of --accept-nth '{n}'), in the order picked:
// each path prefixed with prefix and shell-quoted. A directory's row adds
// nothing. It lists nothing when nothing was picked.
func treeQuote(git func(args ...string) (string, error), r io.Reader, kind, rev, prefix string) (string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return "", err
	}
	picked := splitList(string(data))
	if len(picked) == 0 {
		return "", nil
	}
	rows, err := treeList(git, kind, rev)
	if err != nil {
		return "", err
	}
	var words []string
	for _, s := range picked {
		n, err := strconv.Atoi(s)
		if err != nil || n < 0 || n >= len(rows) {
			return "", fmt.Errorf("no row %q (have %d)", s, len(rows))
		}
		if !rows[n].isDir() {
			words = append(words, shellQuote(prefix+rows[n].path))
		}
	}
	return strings.Join(words, " "), nil
}

// runTree dispatches tree, which writes a revision's list as tree rows, and
// tree-quote, which reads the picked rows' indices on r and writes their words.
func runTree(cmd string, args []string, git func(args ...string) (string, error), r io.Reader, w io.Writer) error {
	var out string
	switch cmd {
	case "tree":
		if len(args) != 2 {
			return errors.New("usage: git-hunk-pick tree KIND REV")
		}
		rows, err := treeList(git, args[0], args[1])
		if err != nil {
			return err
		}
		var b strings.Builder
		for _, row := range rows {
			b.WriteString(row.record())
		}
		out = b.String()
	case "tree-quote":
		if len(args) < 2 || len(args) > 3 {
			return errors.New("usage: git-hunk-pick tree-quote KIND REV [PREFIX]  (the picked rows' indices on stdin)")
		}
		prefix := ""
		if len(args) == 3 {
			prefix = args[2]
		}
		words, err := treeQuote(git, r, args[0], args[1], prefix)
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
