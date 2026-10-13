package main

import (
	"strings"
	"testing"
)

// TestTreeRows lays lists out as trees: subdirectories before files, a chain
// of single directories on one row, the last entry of each with └╴.
func TestTreeRows(t *testing.T) {
	tests := []struct {
		name  string
		paths []string
		want  []string // each row's lines and name, a tab, its path
	}{
		{"nothing", nil, nil},
		{"a file at the root", []string{"a"}, []string{"a\ta"}},
		{
			"a chain of single directories shares one row",
			[]string{"a/b/c/x", "a/b/c/y"},
			[]string{"a/b/c/\ta/b/c/", "├╴x\ta/b/c/x", "└╴y\ta/b/c/y"},
		},
		{
			"a directory with a file is not merged into its parent",
			[]string{"a/b/c/y", "a/x"},
			[]string{"a/\ta/", "├╴b/c/\ta/b/c/", "│ └╴y\ta/b/c/y", "└╴x\ta/x"},
		},
		{
			"a commit across the repo, as listPaths sorts it",
			[]string{
				"CLAUDE.md",
				"packages/custom.nix",
				"packages/git/hunk-pick/main.go",
				"packages/git/hunk-pick/paths.go",
				"sources/.config/shell/functions/git.bash",
				"sources/.config/shell/leader.toml",
				"sources/.config/zsh/.zshrc",
				"wrappers/zsh.nix",
			},
			[]string{
				"packages/\tpackages/",
				"├╴git/hunk-pick/\tpackages/git/hunk-pick/",
				"│ ├╴main.go\tpackages/git/hunk-pick/main.go",
				"│ └╴paths.go\tpackages/git/hunk-pick/paths.go",
				"└╴custom.nix\tpackages/custom.nix",
				"sources/.config/\tsources/.config/",
				"├╴shell/\tsources/.config/shell/",
				"│ ├╴functions/\tsources/.config/shell/functions/",
				"│ │ └╴git.bash\tsources/.config/shell/functions/git.bash",
				"│ └╴leader.toml\tsources/.config/shell/leader.toml",
				"└╴zsh/\tsources/.config/zsh/",
				"  └╴.zshrc\tsources/.config/zsh/.zshrc",
				"wrappers/\twrappers/",
				"└╴zsh.nix\twrappers/zsh.nix",
				"CLAUDE.md\tCLAUDE.md",
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got []string
			for _, r := range treeRows(tt.paths) {
				got = append(got, r.lines+r.name+"\t"+r.path)
			}
			if strings.Join(got, "\n") != strings.Join(tt.want, "\n") {
				t.Errorf("treeRows(%q) =\n%s\nwant\n%s", tt.paths, strings.Join(got, "\n"), strings.Join(tt.want, "\n"))
			}
		})
	}
}

// TestTreeRecord writes the fields fzf reads: the coloured tree row, its
// control characters shown, and the bare path.
func TestTreeRecord(t *testing.T) {
	tests := []struct {
		name string
		row  treeRow
		want string
	}{
		{
			"a directory at the top",
			treeRow{"", "a/b/", "a/b/"},
			treeDirColor + "a/b/" + colorReset + "\x1fa/b/\x00",
		},
		{
			"a file in the tree",
			treeRow{"│ └╴", "x.go", "a/b/x.go"},
			treeLineColor + "│ └╴" + colorReset + "x.go\x1fa/b/x.go\x00",
		},
		{"a file at the top", treeRow{"", "top", "top"}, "top\x1ftop\x00"},
		{
			"control characters",
			treeRow{"└╴", "n\nl\x1b[31m\x1f\x7f\u009b", "d\te/n\nl\x1b[31m\x1f\x7f\u009b"},
			treeLineColor + "└╴" + colorReset + "n␊l␛[31m␟␡�\x1f" +
				"d\te/n\nl\x1b[31m\x1f\x7f\u009b\x00",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.row.record(); got != tt.want {
				t.Errorf("record() = %q, want %q", got, tt.want)
			}
		})
	}
}

// TestTree lists a commit as rows and maps the picked rows' indices back to
// shell words: a directory's row to every file below it. The rows are
// 0 a/, 1 a/b/, 2 a/b/x, 3 a/y, 4 it's, 5 z.
func TestTree(t *testing.T) {
	calls := 0
	list := fakeGit(map[string]string{
		"diff-tree --root --no-commit-id --name-only --diff-merges=first-parent -r -z --end-of-options abc": "z\x00a/y\x00it's\x00a/b/x\x00",
	})
	git := func(args ...string) (string, error) {
		calls++
		return list(args...)
	}

	var b strings.Builder
	if err := runTree("tree", []string{"commit", "abc"}, git, nil, &b); err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, rec := range splitList(b.String()) {
		_, path, _ := strings.Cut(rec, "\x1f") // fzf's {2..}
		paths = append(paths, path)
	}
	if want := "a/ a/b/ a/b/x a/y it's z"; strings.Join(paths, " ") != want {
		t.Errorf("tree rows' paths = %q, want %q", paths, want)
	}

	tests := []struct{ name, in, prefix, want string }{
		{"a file", "5\x00", "", "'z'\n"},
		{"a directory", "0\x00", "", "'a/b/x' 'a/y'\n"},
		{"a directory inside another", "1\x00", "", "'a/b/x'\n"},
		{
			"each file once, in the order picked, with a cd-up prefix",
			"3\x000\x004\x00", "../", `'../a/y' '../a/b/x' '../it'\''s'` + "\n",
		},
		{"no final NUL", "5", "", "'z'\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			if err := runTree("tree-quote", []string{"commit", "abc", tt.prefix}, git, strings.NewReader(tt.in), &b); err != nil {
				t.Fatal(err)
			}
			if b.String() != tt.want {
				t.Errorf("tree-quote = %q, want %q", b.String(), tt.want)
			}
		})
	}

	calls = 0
	b.Reset()
	if err := runTree("tree-quote", []string{"commit", "abc"}, git, strings.NewReader(""), &b); err != nil || b.String() != "" || calls != 0 {
		t.Errorf("tree-quote with nothing picked = %q, %v after %d git calls, want nothing and no call", b.String(), err, calls)
	}

	for _, bad := range []struct {
		cmd  string
		args []string
		in   string
	}{
		{"tree-quote", []string{"commit", "abc"}, "6\x00"},
		{"tree-quote", []string{"commit", "abc"}, "-1\x00"},
		{"tree-quote", []string{"commit", "abc"}, "x\x00"},
		{"tree-quote", []string{"commit"}, "0\x00"},
		{"tree", []string{"commit"}, ""},
		{"tree", []string{"staged", "abc"}, ""},
	} {
		if err := runTree(bad.cmd, bad.args, git, strings.NewReader(bad.in), &b); err == nil {
			t.Errorf("%s %q <%q succeeded, want an error", bad.cmd, bad.args, bad.in)
		}
	}
}
