package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheck(t *testing.T) {
	t.Setenv(envConfigPath, "")
	tests := []struct {
		name    string
		args    []string
		wantErr bool
	}{
		// Allowed defaults.
		{"status", []string{"status"}, false},
		{"log", []string{"log"}, false},
		{"log with flags", []string{"log", "--oneline", "-n", "5"}, false},
		{"diff", []string{"diff", "HEAD~1"}, false},
		{"show", []string{"show", "HEAD"}, false},
		{"branch", []string{"branch", "-a"}, false},
		{"rev-parse", []string{"rev-parse", "HEAD"}, false},
		{"remote", []string{"remote", "-v"}, false},
		{"ls-files", []string{"ls-files"}, false},
		{"blame", []string{"blame", "foo.go"}, false},

		// Safe global flags before the subcommand are skipped (legitimate usage).
		{"-C path then allowed", []string{"-C", "/tmp", "log"}, false},
		{"--git-dir=path then allowed", []string{"--git-dir=/tmp/.git", "log"}, false},
		{"--work-tree=path then allowed", []string{"--work-tree=/tmp", "status"}, false},
		{"--namespace then allowed", []string{"--namespace", "ns", "log"}, false},

		// Exec-injecting global flags are denied even before an allowed subcommand.
		{"-c fsmonitor RCE denied", []string{"-c", "core.fsmonitor=touch x", "status"}, true},
		{"-c pager RCE denied", []string{"-c", "core.pager=!sh", "log"}, true},
		{"-c cosmetic also denied", []string{"-c", "color.ui=always", "log"}, true},
		{"--config-env denied", []string{"--config-env=core.pager=EVIL", "log"}, true},
		{"--config-env spaced denied", []string{"--config-env", "core.pager=EVIL", "log"}, true},
		{"--exec-path denied", []string{"--exec-path=/tmp", "status"}, true},
		{"-c then -C then denied", []string{"-c", "color.ui=always", "-C", "/tmp", "log"}, true},

		// config: reads allowed, writes/edits denied.
		{"config read positional", []string{"config", "user.email"}, false},
		{"config --get read", []string{"config", "--get", "user.email"}, false},
		{"config --list read", []string{"config", "--list"}, false},
		{"config get subcommand read", []string{"config", "get", "user.email"}, false},
		{"config write denied", []string{"config", "user.email", "x@y"}, true},
		{"config --global write denied", []string{"config", "--global", "core.pager", "!sh"}, true},
		{"config --unset denied", []string{"config", "--unset", "core.pager"}, true},
		{"config --add denied", []string{"config", "--add", "core.pager", "x"}, true},
		{"config set subcommand denied", []string{"config", "set", "core.pager", "x"}, true},
		{"config --edit denied", []string{"config", "--edit"}, true},
		{"config -f write denied", []string{"config", "-f", ".git/config", "core.pager", "x"}, true},

		// Denied subcommands.
		{"push", []string{"push"}, true},
		{"commit", []string{"commit", "-m", "foo"}, true},
		{"reset", []string{"reset", "--hard", "HEAD"}, true},
		{"checkout", []string{"checkout", "-b", "new"}, true},
		{"rebase", []string{"rebase", "main"}, true},
		{"stash", []string{"stash"}, true},
		{"clone", []string{"clone", "https://example.com/x"}, true},

		// Denied subcommand reached through safe global-flag skip.
		{"-C path then denied", []string{"-C", "/tmp", "push"}, true},

		// No subcommand → deny.
		{"empty", nil, true},
		{"only -C with value", []string{"-C", "/tmp"}, true},
		{"only --version", []string{"--version"}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := check(tt.args)
			if tt.wantErr && err == nil {
				t.Fatalf("check(%v): want deny, got allow", tt.args)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("check(%v): want allow, got deny: %v", tt.args, err)
			}
		})
	}
}

func TestSanitizeEnv(t *testing.T) {
	in := []string{
		"PATH=/bin",
		"HOME=/home/u",
		"GIT_DIR=/repo/.git",
		"GIT_EXTERNAL_DIFF=evil",
		"GIT_SSH_COMMAND=evil",
		"GIT_PROXY_COMMAND=evil",
		"GIT_ASKPASS=evil",
		"GIT_EDITOR=evil",
		"GIT_SEQUENCE_EDITOR=evil",
		"GIT_PAGER=evil",
		"PAGER=evil",
		"GIT_CONFIG=evil",
		"GIT_CONFIG_GLOBAL=evil",
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=core.pager",
		"GIT_CONFIG_VALUE_0=evil",
		"GIT_CONFIG_PARAMETERS=evil",
	}
	out := sanitizeEnv(in)

	has := func(s string) bool {
		for _, e := range out {
			if e == s {
				return true
			}
		}
		return false
	}
	hasName := func(n string) bool {
		for _, e := range out {
			if strings.HasPrefix(e, n+"=") {
				return true
			}
		}
		return false
	}

	// Safe variables are preserved unchanged.
	for _, e := range []string{"PATH=/bin", "HOME=/home/u", "GIT_DIR=/repo/.git"} {
		if !has(e) {
			t.Errorf("sanitizeEnv dropped safe variable %q", e)
		}
	}

	// Every dangerous variable is stripped.
	for _, n := range []string{
		"GIT_EXTERNAL_DIFF", "GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_ASKPASS",
		"GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "PAGER", "GIT_CONFIG", "GIT_CONFIG_GLOBAL",
		"GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_PARAMETERS",
	} {
		if n == "GIT_PAGER" {
			continue
		}
		if hasName(n) {
			t.Errorf("sanitizeEnv kept dangerous variable %q", n)
		}
	}

	// GIT_PAGER is forced to a non-executing pager, exactly once.
	if !has("GIT_PAGER=cat") {
		t.Error("sanitizeEnv did not force GIT_PAGER=cat")
	}
	n := 0
	for _, e := range out {
		if strings.HasPrefix(e, "GIT_PAGER=") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("GIT_PAGER appears %d times, want exactly 1", n)
	}
}

func TestGitConfigIsWrite(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want bool
	}{
		{"no args", nil, false},
		{"read key", []string{"user.email"}, false},
		{"--get read", []string{"--get", "user.email"}, false},
		{"--list read", []string{"--list"}, false},
		{"-l read", []string{"-l"}, false},
		{"get subcommand", []string{"get", "user.email"}, false},
		{"list subcommand", []string{"list"}, false},
		{"--file read", []string{"--file", "x.cfg", "user.email"}, false},
		{"classic write", []string{"user.email", "a@b"}, true},
		{"scoped write", []string{"--global", "core.pager", "!sh"}, true},
		{"--unset write", []string{"--unset", "core.pager"}, true},
		{"--add write", []string{"--add", "core.pager", "x"}, true},
		{"--edit write", []string{"--edit"}, true},
		{"set subcommand", []string{"set", "core.pager", "x"}, true},
		{"unset subcommand", []string{"unset", "core.pager"}, true},
		{"--file write", []string{"--file", "x.cfg", "core.pager", "x"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := gitConfigIsWrite(tt.args); got != tt.want {
				t.Errorf("gitConfigIsWrite(%v) = %v, want %v", tt.args, got, tt.want)
			}
		})
	}
}

func TestAllowlistExtension(t *testing.T) {
	tests := []struct {
		name    string
		toml    string
		args    []string
		wantErr bool
	}{
		{"unset env denies push", "", []string{"push"}, true},
		{"allow push", `allow = ["push"]`, []string{"push"}, false},
		{"allow multiple", `allow = ["push", "fetch"]`, []string{"fetch"}, false},
		{"empty list still denies", `allow = []`, []string{"push"}, true},
		{"unknown still denied", `allow = ["push"]`, []string{"rebase", "main"}, true},
		{"defaults still allowed", `allow = ["push"]`, []string{"status"}, false},
		{"malformed toml falls back to defaults: push denied", `allow = [`, []string{"push"}, true},
		{"malformed toml falls back to defaults: status allowed", `allow = [`, []string{"status"}, false},
		// Even an allowlisted subcommand cannot smuggle a config-injection flag.
		{"allowlisted push still rejects -c", `allow = ["push"]`, []string{"-c", "core.pager=!sh", "push"}, true},
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
			err := check(tt.args)
			if tt.wantErr && err == nil {
				t.Fatalf("check(%v) toml=%q: want deny, got allow", tt.args, tt.toml)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("check(%v) toml=%q: want allow, got deny: %v", tt.args, tt.toml, err)
			}
		})
	}
}
