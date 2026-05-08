package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestCheckCommand(t *testing.T) {
	tests := []struct {
		name    string
		cmd     string
		wantErr bool
	}{
		{"empty", "", false},
		{"whitespace only", "   \n  ", false},
		{"non-git binary", "ls -la /tmp", false},
		{"echo", "echo hello world", false},

		{"git status", "git status", false},
		{"git log with flags", "git log --oneline -n 5", false},
		{"git diff", "git diff HEAD~1", false},
		{"git rev-parse", "git rev-parse HEAD", false},
		{"git blame", "git blame foo.go", false},
		{"git config get", "git config user.email", false},
		{"git remote", "git remote -v", false},
		{"git ls-files", "git ls-files", false},
		{"git show", "git show HEAD", false},
		{"git branch", "git branch -a", false},

		{"git -C path status", "git -C /tmp status", false},
		{"git -c kv log", "git -c color.ui=always log", false},
		{"git --git-dir=path log", "git --git-dir=/tmp/.git log", false},
		{"git --work-tree=path status", "git --work-tree=/tmp status", false},
		{"git -c then -C", "git -c color.ui=always -C /tmp log", false},

		{"abs path git status", "/usr/bin/git status", false},
		{"abs path git push", "/usr/bin/git push", true},

		{"git push", "git push", true},
		{"git commit", "git commit -m foo", true},
		{"git reset hard", "git reset --hard HEAD~1", true},
		{"git checkout new branch", "git checkout -b new", true},
		{"git rebase", "git rebase main", true},
		{"git stash", "git stash", true},

		{"forbidden --force on diff", "git diff --force", true},
		{"forbidden -f on diff", "git diff -f", true},
		{"forbidden --no-verify on diff", "git diff --no-verify", true},
		{"forbidden --force= form", "git diff --force=foo", true},

		{"bash -c allow", `bash -c "git status"`, false},
		{"bash -c deny", `bash -c "git push"`, true},
		{"sh -c deny force", `sh -c 'git push --force'`, true},
		{"zsh -c allow", `zsh -c "git -C /tmp diff"`, false},
		{"abs sh -c deny", `/bin/sh -c "git commit"`, true},
		{"dash -c deny", `dash -c "git reset --hard"`, true},

		{"compound allow both", "git status && git log", false},
		{"compound deny second", "git status && git push", true},
		{"compound deny first", "git push && git log", true},
		{"pipe allow", "git log | head", false},
		{"pipe deny", "git push | head", true},
		{"semicolon deny", "echo hi; git push", true},
		{"or deny", "git status || git commit", true},

		{"cmd subst deny", `echo "$(git push)"`, true},
		{"cmd subst allow", `echo "$(git status)"`, false},
		{"backtick deny", "echo `git push`", true},

		{"variable subcommand", "git $sub", true},
		{"subst subcommand", "git $(echo push)", true},

		{"git no sub", "git", true},
		{"git only -C", "git -C /tmp", true},
		{"git only flags", "git -c color.ui=always", true},

		{"unterminated quote", "git status 'unterminated", true},
		{"unterminated subst", "git status $(echo", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := checkCommand(tt.cmd)
			if tt.wantErr && err == nil {
				t.Fatalf("checkCommand(%q): want deny, got allow", tt.cmd)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("checkCommand(%q): want allow, got deny: %v", tt.cmd, err)
			}
		})
	}
}

func TestDecide(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		wantDeny bool
	}{
		{"allow git status", `{"tool_name":"Bash","tool_input":{"command":"git status"}}`, false},
		{"deny git push", `{"tool_name":"Bash","tool_input":{"command":"git push"}}`, true},
		{"non-bash tool passes through", `{"tool_name":"Edit","tool_input":{"command":"git push"}}`, false},
		{"empty command allow", `{"tool_name":"Bash","tool_input":{"command":""}}`, false},
		{"missing tool_name treated as bash", `{"tool_input":{"command":"git push"}}`, true},
		{"malformed JSON denies (fail closed)", `{not json`, true},
		{"empty stdin denies (fail closed)", "", true},
		{"truncated JSON denies (fail closed)", `{"tool_name":"Bash"`, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out := decide(strings.NewReader(tt.body))
			if tt.wantDeny {
				if out == nil {
					t.Fatal("decide: want deny, got allow")
				}
				if got := out.HookSpecificOutput.PermissionDecision; got != "deny" {
					t.Errorf("permissionDecision = %q, want deny", got)
				}
				if got := out.HookSpecificOutput.HookEventName; got != "PreToolUse" {
					t.Errorf("hookEventName = %q, want PreToolUse", got)
				}
				if out.HookSpecificOutput.PermissionDecisionReason == "" {
					t.Error("permissionDecisionReason is empty")
				}
				return
			}
			if out != nil {
				t.Fatalf("decide: want allow, got deny: %+v", out)
			}
		})
	}
}

func TestEmittedJSONShape(t *testing.T) {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(denyOutput("test reason")); err != nil {
		t.Fatal(err)
	}
	want := `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"git-allowlist: test reason"}}` + "\n"
	if got := buf.String(); got != want {
		t.Errorf("encoded JSON =\n  got: %s\n want: %s", got, want)
	}
}
