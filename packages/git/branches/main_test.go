package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
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

// TestRunFzf drives runFzf through fzf's non-interactive --filter mode: the
// lines reach fzf, the matches come back one per line, a query that matches
// nothing selects nothing, and $FZF_DEFAULT_OPTS applies as it does to the
// fzf command.
func TestRunFzf(t *testing.T) {
	lines := []string{"main", "feat/x", "origin/feat/x"}
	tests := []struct {
		name, defaults, query, want string
	}{
		{name: "matches in list order", query: "fx", want: "feat/x\norigin/feat/x"},
		{name: "no match selects nothing", query: "zzz", want: ""},
		{name: "FZF_DEFAULT_OPTS applies", defaults: "--exact", query: "fx", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("FZF_DEFAULT_OPTS_FILE", "")
			t.Setenv("FZF_DEFAULT_OPTS", tt.defaults)
			got, err := runFzf(lines, "--no-sort", "--filter="+tt.query)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
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

// TestCherryPickCmd: the picked commits come out oldest first, whatever order
// fzf returned them in, so each lands on the one it was made after.
func TestCherryPickCmd(t *testing.T) {
	commits := []string{"c3 third", "c2 second", "c1 first"} // git log order
	tests := []struct {
		name, selected, want string
	}{
		{"ctrl-a returns list order, newest first", "c3 third\nc2 second\nc1 first", "git cherry-pick 'c1' 'c2' 'c3'"},
		{"a selection made out of order", "c1 first\nc3 third", "git cherry-pick 'c1' 'c3'"},
		{"nothing picked", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := cherryPickCmd(commits, tt.selected); got != tt.want {
				t.Errorf("got  %s\nwant %s", got, tt.want)
			}
		})
	}
}

// TestWorktreeAddCmd: a remote-only branch gets a local branch tracking it,
// not a detached checkout of the remote-tracking ref.
func TestWorktreeAddCmd(t *testing.T) {
	tests := []struct {
		name, branch, local, want string
	}{
		{"a local branch", "feat", "", "git worktree add --end-of-options '/r_1' 'feat' && builtin cd '/r_1' "},
		{
			"a remote-only branch", "origin/feat/x", "feat/x",
			"git worktree add --track -b 'feat/x' --end-of-options '/r_1' 'origin/feat/x' && builtin cd '/r_1' ",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := worktreeAddCmd("/r_1", tt.branch, tt.local); got != tt.want {
				t.Errorf("got  %s\nwant %s", got, tt.want)
			}
		})
	}
}

// TestWorktreeRemoveCmd: the shell leaves a removed worktree first from
// anywhere inside it, not only from its top.
func TestWorktreeRemoveCmd(t *testing.T) {
	tests := []struct {
		name, cwd string
		paths     []string
		want      string
	}{
		{"from its top", "/r_1", []string{"/r_1"}, "builtin cd '/r' && git worktree remove --end-of-options '/r_1' && ls"},
		{"from a subdirectory", "/r_1/a/b", []string{"/r_2", "/r_1"}, "builtin cd '/r' && git worktree remove --end-of-options '/r_2' && git worktree remove --end-of-options '/r_1' && ls"},
		{"from a sibling that shares its prefix", "/r_10", []string{"/r_1"}, "git worktree remove --end-of-options '/r_1' && ls"},
		{"from the main worktree", "/r", []string{"/r_1"}, "git worktree remove --end-of-options '/r_1' && ls"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := worktreeRemoveCmd(tt.cwd, "/r", tt.paths); got != tt.want {
				t.Errorf("got  %s\nwant %s", got, tt.want)
			}
		})
	}
}

// TestStashApplyCmd stashes f.txt's first line, then runs the command gsy
// prints from a subdirectory: it applies the line to the file as stashed from,
// and refuses a file edited since, keeping the edit (git restore --source
// replaced the file with the stash's copy). Each case leaves f.txt a second
// newer than the index has it, so apply's stat check can't settle either one.
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
			later := time.Now().Add(2 * time.Second)
			if err := os.Chtimes("f.txt", later, later); err != nil {
				t.Fatal(err)
			}
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
