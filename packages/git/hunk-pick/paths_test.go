package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestListPaths builds each kind from its git outputs: -z lists verbatim, git
// clean's dry run unquoted, all sorted and deduplicated.
func TestListPaths(t *testing.T) {
	git := fakeGit(map[string]string{
		"diff --cached --name-only -z":            "s.txt\x00b.txt\x00",
		"diff --name-only -z":                     "b.txt\x00café.txt\x00",
		"ls-files --others --exclude-standard -z": "a b.txt\x00new\nline\x00",
		"clean --dry-run -d": "Would remove a b.txt\nWould remove \"caf\\303\\251\\tx.txt\"\n" +
			"Would remove dir/\nWould skip repository sub/\n",
		"ls-files --others --ignored --exclude-standard --directory -z":          "build/\x00debug run.log\x00",
		"diff-tree --root --no-commit-id --name-only -r -z --end-of-options abc": "x.go\x00y.go\x00",
		"ls-tree -r --full-tree --name-only -z --end-of-options abc":             "a\x00b/c\x00",
	})
	tests := []struct {
		kind, rev string
		want      []string
	}{
		{"staged", "", []string{"b.txt", "s.txt"}},
		{"unstaged", "", []string{"a b.txt", "b.txt", "café.txt", "new\nline"}},
		{"changed", "", []string{"a b.txt", "b.txt", "café.txt", "new\nline", "s.txt"}},
		{"untracked", "", []string{"a b.txt", "café\tx.txt", "dir/"}},
		{"ignored", "", []string{"build/", "debug run.log"}},
		{"commit", "abc", []string{"x.go", "y.go"}},
		{"tree", "abc", []string{"a", "b/c"}},
	}
	for _, tt := range tests {
		t.Run(tt.kind, func(t *testing.T) {
			got, err := listPaths(git, tt.kind, tt.rev)
			if err != nil {
				t.Fatal(err)
			}
			if joinList(got) != joinList(tt.want) {
				t.Errorf("%s = %q, want %q", tt.kind, got, tt.want)
			}
		})
	}
	for _, bad := range [][2]string{{"nope", ""}, {"commit", ""}, {"staged", "abc"}} {
		if _, err := listPaths(git, bad[0], bad[1]); err == nil {
			t.Errorf("listPaths(%q, %q) succeeded, want an error", bad[0], bad[1])
		}
	}
}

// TestQuote turns fzf's --print0 selection into the printed command's words.
func TestQuote(t *testing.T) {
	tests := []struct{ name, in, prefix, want string }{
		{"nothing picked", "", "", ""},
		{"one path", "a.txt\x00", "", "'a.txt'\n"},
		{"a quote, a space and a cd-up prefix", "it's.txt\x00a b\x00", "../", `'../it'\''s.txt' '../a b'` + "\n"},
		{"a name git would quote stays verbatim", "café\tx\n.txt\x00", "", "'café\tx\n.txt'\n"},
		{"no final NUL", "a\x00b", "", "'a' 'b'\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			if err := runPaths("quote", []string{tt.prefix}, strings.NewReader(tt.in), &b); err != nil {
				t.Fatal(err)
			}
			if b.String() != tt.want {
				t.Errorf("quote = %q, want %q", b.String(), tt.want)
			}
		})
	}
}

// TestPathsRealGit lists each kind from a real repo: names git would quote,
// an untracked directory that git clean empties but keeps (it holds an
// ignored file), and a commit and a tree listed whole from a subdirectory.
func TestPathsRealGit(t *testing.T) {
	repo := t.TempDir()
	t.Setenv("HOME", repo)
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	t.Setenv("LC_ALL", "C") // runPaths sets it too; this restores it afterwards
	for _, v := range []string{"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"} {
		t.Setenv(v, "t")
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	chdir := func(t *testing.T, dir string) {
		t.Helper()
		if err := os.Chdir(dir); err != nil {
			t.Fatal(err)
		}
	}
	chdir(t, repo)
	git := func(t *testing.T, args ...string) {
		t.Helper()
		if _, err := runGit(args...); err != nil {
			t.Fatalf("git %s: %v", strings.Join(args, " "), err)
		}
	}
	write := func(t *testing.T, name, s string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(name), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(name, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	git(t, "init", "-q")
	for _, f := range []string{"café.txt", "a b.txt", "sub/s.txt"} {
		write(t, f, "1\n")
	}
	write(t, ".gitignore", "*.log\n")
	git(t, "add", "-A")
	git(t, "commit", "-qm", "base")
	write(t, "sub/s.txt", "2\n")
	git(t, "commit", "-qam", "sub")
	write(t, "café.txt", "2\n")
	write(t, "a b.txt", "2\n")
	git(t, "add", "a b.txt")
	for _, f := range []string{"new\tfile", "newdir/x.txt", "newdir/y.log", "whole/w.txt", "debug run.log"} {
		write(t, f, "x\n")
	}

	all := []string{".gitignore", "a b.txt", "café.txt", "sub/s.txt"}
	tests := []struct {
		dir  string // where paths runs: the root, as __git_fzf_select does, or sub
		args []string
		want []string
	}{
		{".", []string{"staged"}, []string{"a b.txt"}},
		{".", []string{"unstaged"}, []string{"café.txt", "new\tfile", "newdir/x.txt", "whole/w.txt"}},
		{".", []string{"changed"}, []string{"a b.txt", "café.txt", "new\tfile", "newdir/x.txt", "whole/w.txt"}},
		{".", []string{"untracked"}, []string{"new\tfile", "newdir/x.txt", "whole/"}},
		{".", []string{"ignored"}, []string{"debug run.log", "newdir/y.log"}},
		{"sub", []string{"commit", "HEAD"}, []string{"sub/s.txt"}},
		{"sub", []string{"commit", "HEAD~"}, all},
		{"sub", []string{"tree", "HEAD"}, all},
	}
	for _, tt := range tests {
		t.Run(strings.Join(tt.args, " "), func(t *testing.T) {
			chdir(t, filepath.Join(repo, tt.dir))
			var b strings.Builder
			if err := runPaths("paths", tt.args, nil, &b); err != nil {
				t.Fatal(err)
			}
			if b.String() != joinList(tt.want) {
				t.Errorf("paths %s = %q, want %q", strings.Join(tt.args, " "), b.String(), joinList(tt.want))
			}
		})
	}
}
