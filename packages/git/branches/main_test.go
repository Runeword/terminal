package main

import "testing"

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
