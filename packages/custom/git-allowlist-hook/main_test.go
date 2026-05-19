package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckCommand(t *testing.T) {
	t.Setenv(envConfigPath, "")
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

		// Combined-flag shell escape.
		{"bash -ec deny", `bash -ec 'git push'`, true},
		{"bash -ec allow", `bash -ec 'git status'`, false},
		{"sh -uec deny", `sh -uec 'git push'`, true},
		{"zsh -ec deny hard reset", `zsh -ec 'git reset --hard'`, true},
		{"abs sh -ec deny", `/bin/sh -ec 'git commit'`, true},
		{"multiple -c both checked", `bash -c 'git status' -c 'git push'`, true},

		// eval recursion.
		{"eval deny", `eval 'git push'`, true},
		{"eval allow", `eval 'git status'`, false},
		{"eval multi-arg join deny", `eval git push`, true},
		{"eval non-literal deny", `eval $cmd`, true},
		{"eval empty allow", `eval ''`, false},
		{"eval no args allow", `eval`, false},

		// Command-prefix wrappers.
		{"xargs git push deny", `xargs git push`, true},
		{"xargs git status allow", `xargs git status`, false},
		{"xargs -I {} git push deny", `xargs -I {} git push`, true},
		{"xargs -n 1 git push deny", `xargs -n 1 git push`, true},
		{"pipe to xargs deny", `echo HEAD | xargs git push`, true},
		{"pipe to xargs allow", `echo HEAD | xargs git show`, false},
		{"env GIT_PAGER deny", `env GIT_PAGER=cat git push`, true},
		{"env GIT_PAGER allow", `env GIT_PAGER=cat git status`, false},
		{"env -u git push deny", `env -u FOO git push`, true},
		{"nice git push deny", `nice git push`, true},
		{"nice -n 5 git push deny", `nice -n 5 git push`, true},
		{"timeout git push deny", `timeout 5 git push`, true},
		{"timeout git status allow", `timeout 5 git status`, false},
		{"timeout -s git push deny", `timeout -s KILL 5 git push`, true},
		{"command git push deny", `command git push`, true},
		{"exec git push deny", `exec git push`, true},
		{"stdbuf git push deny", `stdbuf -o0 git push`, true},
		{"xargs env chain deny", `xargs env GIT_PAGER=cat git push`, true},
		{"xargs bash -c deny", `xargs bash -c 'git push'`, true},

		// Dangerous -c config keys.
		{"-c fsmonitor RCE deny", `git -c core.fsmonitor='!evil' status`, true},
		{"-c fsmonitor space form deny", `git -c core.fsmonitor=!evil status`, true},
		{"-c pager deny", `git -c core.pager='!evil' log`, true},
		{"-c sshcommand deny", `git -c core.sshCommand='!evil' status`, true},
		{"-c alias prefix deny", `git -c alias.x='!evil' log`, true},
		{"-c pager prefix deny", `git -c pager.log='!evil' log`, true},
		{"-c url prefix deny", `git -c url.evil.insteadof=https://github.com log`, true},
		{"-c safe.directory deny", `git -c safe.directory=* status`, true},
		{"-c color.ui still allow", `git -c color.ui=always log`, false},
		{"-c separate value deny", `git -c core.pager=cat log`, true},
		{"--config-env dangerous deny", `git --config-env=core.pager=PAGER log`, true},
		{"--config-env benign allow", `git --config-env=color.ui=COLOR log`, false},

		// --exec-path always denied.
		{"--exec-path= deny", `git --exec-path=/tmp/evil status`, true},
		{"--exec-path bare deny", `git --exec-path status`, true},

		// git config write detection.
		{"git config write 2 args deny", `git config user.email new@email.com`, true},
		{"git config alias write deny", `git config alias.x '!evil'`, true},
		{"git config --add deny", `git config --add user.email new@email.com`, true},
		{"git config --unset deny", `git config --unset user.name`, true},
		{"git config --unset-all deny", `git config --unset-all user.email`, true},
		{"git config --replace-all deny", `git config --replace-all user.email new@email.com`, true},
		{"git config --rename-section deny", `git config --rename-section old new`, true},
		{"git config --remove-section deny", `git config --remove-section old`, true},
		{"git config --edit deny", `git config --edit`, true},
		{"git config -e deny", `git config -e`, true},
		{"git config --get-regexp 2 args allow", `git config --get-regexp 'user\..*' value`, false},
		{"git config --get allow", `git config --get user.email`, false},
		{"git config --type with arg allow", `git config --type int branch.master.remote`, false},
		{"git config --list allow", `git config --list`, false},
		{"git config -l allow", `git config -l`, false},
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

func TestConfigAllowExtra(t *testing.T) {
	tests := []struct {
		name    string
		toml    string // file contents; empty means env var is unset
		cmd     string
		wantErr bool
	}{
		{"unset env still denies push", "", "git push", true},
		{"allow push", `allow = ["push"]`, "git push", false},
		{"allow multiple", `allow = ["push", "fetch"]`, "git fetch", false},
		{"empty list still denies", `allow = []`, "git push", true},
		{"unknown still denied", `allow = ["push"]`, "git rebase main", true},
		{"forbidden flag still wins", `allow = ["push"]`, "git push --force", true},
		{"defaults still allowed", `allow = ["push"]`, "git status", false},
		{"applies via bash -c", `allow = ["push"]`, `bash -c "git push"`, false},
		{"applies via xargs", `allow = ["push"]`, `xargs git push`, false},
		{"malformed toml falls back to defaults", `allow = [`, "git push", true},
		{"malformed toml does not break defaults", `allow = [`, "git status", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(envConfigPath, "")
			if tt.toml != "" {
				path := filepath.Join(t.TempDir(), "git-allowlist.toml")
				if err := os.WriteFile(path, []byte(tt.toml), 0o644); err != nil {
					t.Fatal(err)
				}
				t.Setenv(envConfigPath, path)
			}
			err := checkCommand(tt.cmd)
			if tt.wantErr && err == nil {
				t.Fatalf("checkCommand(%q) with toml=%q: want deny, got allow", tt.cmd, tt.toml)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("checkCommand(%q) with toml=%q: want allow, got deny: %v", tt.cmd, tt.toml, err)
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
