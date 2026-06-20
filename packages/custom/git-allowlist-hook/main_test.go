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

		// Allowed subcommands.
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

		// Safe global flags are skipped to find the subcommand.
		{"git -C path status", "git -C /tmp status", false},
		{"git --git-dir=path log", "git --git-dir=/tmp/.git log", false},
		{"git --work-tree=path status", "git --work-tree=/tmp status", false},

		// Exec-injecting global flags are denied (RCE through allowed subcommands).
		{"git -c fsmonitor RCE denied", "git -c core.fsmonitor='touch x' status", true},
		{"git -c pager RCE denied", "git -c core.pager='!sh' log", true},
		{"git -c cosmetic also denied", "git -c color.ui=always log", true},
		{"git --config-env denied", "git --config-env=core.pager=EVIL log", true},
		{"git --exec-path denied", "git --exec-path=/tmp status", true},
		{"git -c then -C denied", "git -c color.ui=always -C /tmp log", true},

		// Absolute-path git (shim-bypassing) gets the same flag/config checks.
		{"abs path -c denied", "/usr/bin/git -c core.pager=x log", true},

		// Exec-capable env assignment on a direct git call is denied — the shim
		// strips these for PATH git but cannot for absolute-path git.
		{"env GIT_EXTERNAL_DIFF denied", "GIT_EXTERNAL_DIFF=evil git diff", true},
		{"env GIT_PAGER denied", "GIT_PAGER=evil git log", true},
		{"env GIT_SSH_COMMAND denied", "GIT_SSH_COMMAND=evil git status", true},
		{"env GIT_CONFIG_COUNT denied", "GIT_CONFIG_COUNT=1 git status", true},
		{"env GIT_CONFIG_KEY_0 denied", "GIT_CONFIG_KEY_0=core.pager git log", true},
		{"env on abs-path git denied", "GIT_EXTERNAL_DIFF=evil /usr/bin/git diff", true},
		{"benign env assignment allowed", "FOO=bar git status", false},

		// config: reads allowed, writes/edits denied.
		{"config --get read", "git config --get user.email", false},
		{"config --list read", "git config --list", false},
		{"config get subcommand read", "git config get user.email", false},
		{"config write denied", "git config user.email a@b", true},
		{"config global write denied", "git config --global core.pager '!sh'", true},
		{"config unset denied", "git config --unset core.pager", true},
		{"config set subcommand denied", "git config set core.pager x", true},
		{"config edit denied", "git config --edit", true},

		// Absolute path: hook normalizes via path.Base. This is the case the
		// PATH shim cannot see, so it is the hook's main reason to exist.
		{"abs path git status", "/usr/bin/git status", false},
		{"abs path git push", "/usr/bin/git push", true},

		// Denied subcommands.
		{"git push", "git push", true},
		{"git commit", "git commit -m foo", true},
		{"git reset hard", "git reset --hard HEAD~1", true},
		{"git checkout new branch", "git checkout -b new", true},
		{"git rebase", "git rebase main", true},
		{"git stash", "git stash", true},

		// Compound shell: walker visits every CallExpr.
		{"compound allow both", "git status && git log", false},
		{"compound deny second", "git status && git push", true},
		{"compound deny first", "git push && git log", true},
		{"pipe allow", "git log | head", false},
		{"pipe deny", "git push | head", true},
		{"semicolon deny", "echo hi; git push", true},
		{"or deny", "git status || git commit", true},

		// Command substitution: walker recurses into $(...) and `...`.
		{"cmd subst deny", `echo "$(git push)"`, true},
		{"cmd subst allow", `echo "$(git status)"`, false},
		{"backtick deny", "echo `git push`", true},

		// Non-literal subcommand cannot be analysed → deny.
		{"variable subcommand", "git $sub", true},
		{"subst subcommand", "git $(echo push)", true},

		// No subcommand.
		{"git no sub", "git", true},
		{"git only -C", "git -C /tmp", true},
		{"git only flags", "git -c color.ui=always", true},

		// Unparseable shell → deny (fail closed).
		{"unterminated quote", "git status 'unterminated", true},
		{"unterminated subst", "git status $(echo", true},

		// Cases the hook deliberately PASSES THROUGH (no recursion). The PATH
		// shim catches the inner git invocation at exec time. These are tested
		// for "allow" to document the intentional contract.
		{"bash -c passes through", `bash -c "git push"`, false},
		{"sh -c passes through", `sh -c 'git push'`, false},
		{"bash -ec passes through", `bash -ec 'git push'`, false},
		{"eval passes through", `eval 'git push'`, false},
		{"xargs passes through", `xargs git push`, false},
		{"env binary prefix passes through", `env GIT_PAGER=cat git push`, false},
		{"nice passes through", `nice git push`, false},
		{"timeout passes through", `timeout 5 git push`, false},
		{"heredoc passes through", "bash <<'EOF'\ngit push\nEOF\n", false},
		{"pipe to bash passes through", "echo 'git push' | bash", false},
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
		toml    string
		cmd     string
		wantErr bool
	}{
		{"unset env still denies push", "", "git push", true},
		{"allow push", `allow = ["push"]`, "git push", false},
		{"allow multiple", `allow = ["push", "fetch"]`, "git fetch", false},
		{"empty list still denies", `allow = []`, "git push", true},
		{"unknown still denied", `allow = ["push"]`, "git rebase main", true},
		{"defaults still allowed", `allow = ["push"]`, "git status", false},
		{"malformed toml falls back to defaults", `allow = [`, "git push", true},
		{"malformed toml does not break defaults", `allow = [`, "git status", false},
		// An allowlisted subcommand still cannot smuggle a config-injection flag.
		{"allowlisted push still rejects -c", `allow = ["push"]`, "git -c core.pager=!sh push", true},
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
