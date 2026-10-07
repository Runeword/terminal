package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// mustGit runs git in the current dir and fails the test on error.
func mustGit(t *testing.T, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", args...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// setupRepo makes an isolated repo with one commit (f.txt) and chdirs into it.
func setupRepo(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@t")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@t")

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	mustGit(t, "init", "-q")
	write(t, "f.txt", "a\nb\nc\nd\ne\nf\ng\n")
	mustGit(t, "add", "f.txt")
	mustGit(t, "commit", "-qm", "init")
}

// TestStashHunkLeavesIndexUntouched stashes one unstaged hunk while an unrelated
// staged change stays staged, and asserts the real index is untouched, the hunk
// is gone from the worktree (the other unstaged hunk stays), and the stash holds
// only that hunk.
func TestStashHunkLeavesIndexUntouched(t *testing.T) {
	setupRepo(t)

	// Unrelated staged change (line 8), then two unstaged hunks (line 1, line 7).
	write(t, "f.txt", "a\nb\nc\nd\ne\nf\ng\nSTAGED\n")
	mustGit(t, "add", "f.txt")
	write(t, "f.txt", "A\nb\nc\nd\ne\nf\nG\nSTAGED\n")
	stagedBefore := mustGit(t, "diff", "--cached")

	// Minimal zero-context patch for the first hunk (line 1: a -> A).
	patch := "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-a\n+A\n"
	if err := run([]byte(patch), nil, "partial"); err != nil {
		t.Fatalf("run: %v", err)
	}

	if got := mustGit(t, "stash", "list"); got == "" || strings.Count(got, "\n") != 0 {
		t.Fatalf("expected exactly one stash, got: %q", got)
	}
	if got := mustGit(t, "diff", "--cached"); got != stagedBefore {
		t.Fatalf("real index was modified.\nbefore:\n%s\nafter:\n%s", stagedBefore, got)
	}
	if got := read(t, "f.txt"); got != "a\nb\nc\nd\ne\nf\nG\nSTAGED\n" {
		t.Fatalf("worktree = %q, want only the first hunk removed", got)
	}
	show := mustGit(t, "stash", "show", "-p", "stash@{0}")
	if !strings.Contains(show, "-a") || !strings.Contains(show, "+A") {
		t.Fatalf("stash missing the picked hunk:\n%s", show)
	}
	if strings.Contains(show, "STAGED") || strings.Contains(show, "+G") {
		t.Fatalf("stash leaked an unpicked change:\n%s", show)
	}
}

// TestStashHunkPopsBackInPlace stashes a zero-context insertion below two
// staged lines, then pops it: the line must come back where it was, with the
// staged lines still staged. Built on HEAD's tree, the stash held it two lines
// off.
func TestStashHunkPopsBackInPlace(t *testing.T) {
	setupRepo(t)

	write(t, "f.txt", "S1\nS2\na\nb\nc\nd\ne\nf\ng\n")
	mustGit(t, "add", "f.txt")
	staged := mustGit(t, "show", ":f.txt")
	const worktree = "S1\nS2\na\nb\nc\nd\ne\nNEW\nf\ng\n"
	write(t, "f.txt", worktree)

	// The zero-context hunk git diff gives for NEW, after the index's line 7.
	patch := "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -7,0 +8 @@\n+NEW\n"
	if err := run([]byte(patch), nil, "partial"); err != nil {
		t.Fatalf("run: %v", err)
	}
	mustGit(t, "stash", "pop", "-q")

	if got := read(t, "f.txt"); got != worktree {
		t.Errorf("f.txt after pop = %q, want %q", got, worktree)
	}
	if got := mustGit(t, "show", ":f.txt"); got != staged {
		t.Errorf("index after pop = %q, want %q", got, staged)
	}
}

// TestStashWholeFiles stashes a whole tracked file plus a whole untracked file
// and asserts both leave the worktree and land in the stash.
func TestStashWholeFiles(t *testing.T) {
	setupRepo(t)

	write(t, "f.txt", "a\nb\nc\nd\ne\nf\nG\n") // tracked, unstaged change
	write(t, "new.txt", "brand new\n")         // untracked

	if err := run(nil, []string{"f.txt", "new.txt"}, "whole"); err != nil {
		t.Fatalf("run: %v", err)
	}

	if got := mustGit(t, "stash", "list"); got == "" {
		t.Fatal("expected a stash entry")
	}
	// Tracked file reverted to HEAD; untracked file removed from the worktree.
	if got := read(t, "f.txt"); got != "a\nb\nc\nd\ne\nf\ng\n" {
		t.Fatalf("f.txt = %q, want reverted to HEAD", got)
	}
	if _, err := os.Stat("new.txt"); !os.IsNotExist(err) {
		t.Fatalf("new.txt should have been removed from the worktree (err=%v)", err)
	}
	show := mustGit(t, "stash", "show", "-p", "--include-untracked", "stash@{0}")
	if !strings.Contains(show, "+G") || !strings.Contains(show, "brand new") {
		t.Fatalf("stash missing tracked or untracked content:\n%s", show)
	}
}

// TestStashWholeFileIsLiteral stashes the untracked f[1].txt, whose name is
// also a glob that matches the tracked, modified f1.txt: f1.txt must stay put.
func TestStashWholeFileIsLiteral(t *testing.T) {
	setupRepo(t)

	write(t, "f1.txt", "one\n")
	mustGit(t, "add", "f1.txt")
	mustGit(t, "commit", "-qm", "f1")
	write(t, "f1.txt", "ONE\n")       // tracked, unstaged change
	write(t, "f[1].txt", "bracket\n") // untracked

	if err := run(nil, []string{"f[1].txt"}, "literal"); err != nil {
		t.Fatalf("run: %v", err)
	}

	if got := read(t, "f1.txt"); got != "ONE\n" {
		t.Errorf("f1.txt = %q, want its change left in place", got)
	}
	if _, err := os.Stat("f[1].txt"); !os.IsNotExist(err) {
		t.Errorf("f[1].txt should have been removed from the worktree (err=%v)", err)
	}
	if show := mustGit(t, "stash", "show", "-p", "stash@{0}"); !strings.Contains(show, "+bracket") || strings.Contains(show, "ONE") {
		t.Errorf("stash should hold f[1].txt alone:\n%s", show)
	}
}

func write(t *testing.T, name, content string) {
	t.Helper()
	if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
