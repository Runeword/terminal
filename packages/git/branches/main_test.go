package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestWorktreeChoice(t *testing.T) {
	tests := []struct {
		name     string
		wt       worktree
		wantLine string
		wantOK   bool
	}{
		{
			name:     "attached branch strips refs/heads and truncates sha",
			wt:       worktree{path: "/home/u/repo", head: "abcdef1234567890", branch: "refs/heads/main"},
			wantLine: "repo\tabcdef1\t[main]\t/home/u/repo\tmain",
			wantOK:   true,
		},
		{
			name:     "branch name with slash is preserved",
			wt:       worktree{path: "/home/u/repo_1", head: "0123456789", branch: "refs/heads/feat/x"},
			wantLine: "repo_1\t0123456\t[feat/x]\t/home/u/repo_1\tfeat/x",
			wantOK:   true,
		},
		{
			name:     "detached uses full sha as the preview target",
			wt:       worktree{path: "/home/u/repo_2", head: "deadbeefcafe", detached: true},
			wantLine: "repo_2\tdeadbee\t(detached)\t/home/u/repo_2\tdeadbeefcafe",
			wantOK:   true,
		},
		{
			name:     "empty branch is treated as detached",
			wt:       worktree{path: "/tmp/wt", head: "feedface"},
			wantLine: "wt\tfeedfac\t(detached)\t/tmp/wt\tfeedface",
			wantOK:   true,
		},
		{
			name:     "sha shorter than 7 chars is left intact",
			wt:       worktree{path: "/r", head: "abc", branch: "refs/heads/x"},
			wantLine: "r\tabc\t[x]\t/r\tx",
			wantOK:   true,
		},
		{
			name:   "bare worktree is skipped",
			wt:     worktree{path: "/home/u/repo.git", bare: true},
			wantOK: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			line, ok := worktreeChoice(tt.wt)
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if ok && line != tt.wantLine {
				t.Errorf("line  = %q\nwant  = %q", line, tt.wantLine)
			}
		})
	}
}

func TestEditorCmd(t *testing.T) {
	tests := []struct {
		name  string
		cdup  string
		files []string
		want  string
	}{
		{
			name:  "a name nvim would run as +cmd comes after --",
			files: []string{"+so x.vim", ""},
			want:  "nvim -- '+so x.vim'",
		},
		{
			name:  "paths resolve from a subdirectory, quoted",
			cdup:  "../",
			files: []string{"a b", "it's"},
			want:  `nvim -- '../a b' '../it'\''s'`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := editorCmd("nvim", tt.cdup, tt.files); got != tt.want {
				t.Errorf("got  %s\nwant %s", got, tt.want)
			}
		})
	}
}

// TestStashApplyCmd stashes f.txt's first line, then runs the command gsy
// prints from a subdirectory: it applies the line to the file as stashed from,
// and refuses a file edited since, keeping the edit (git restore --source
// replaced the file with the stash's copy).
func TestStashApplyCmd(t *testing.T) {
	repo := t.TempDir()
	t.Setenv("HOME", repo)
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	for _, v := range []string{"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"} {
		t.Setenv(v, "t")
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	git := func(t *testing.T, args ...string) string {
		t.Helper()
		out, err := exec.Command("git", args...).CombinedOutput()
		if err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
		return strings.TrimSpace(string(out))
	}
	writeF := func(t *testing.T, s string) {
		t.Helper()
		if err := os.WriteFile("f.txt", []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	const base = "a\nb\nc\nd\ne\nf\ng\n"
	git(t, "init", "-q")
	writeF(t, base)
	git(t, "add", "f.txt")
	git(t, "commit", "-qm", "base")
	writeF(t, "A\nb\nc\nd\ne\nf\ng\n")
	git(t, "stash", "-q")
	cmd := stashApplyCmd(git(t, "rev-parse", "stash@{0}"), "../", []string{"f.txt"})
	if err := os.Mkdir("sub", 0o700); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name, before, want string
		fails              bool
	}{
		{name: "applies to the file as stashed from", before: base, want: "A\nb\nc\nd\ne\nf\ng\n"},
		{name: "keeps an edit made since", before: "a\nb\nc\nd\ne\nf\nG\n", want: "a\nb\nc\nd\ne\nf\nG\n", fails: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			git(t, "reset", "-q", "--hard")
			writeF(t, tt.before)
			sh := exec.Command("sh", "-c", cmd)
			sh.Dir = "sub"
			out, err := sh.CombinedOutput()
			t.Logf("%s\n%s", cmd, out)
			if (err != nil) != tt.fails {
				t.Errorf("command error = %v, want failure %v", err, tt.fails)
			}
			if got, _ := os.ReadFile("f.txt"); string(got) != tt.want {
				t.Errorf("f.txt = %q, want %q", got, tt.want)
			}
		})
	}
}
