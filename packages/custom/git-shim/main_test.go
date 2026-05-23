package main

import (
	"os"
	"path/filepath"
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
		{"config read", []string{"config", "user.email"}, false},
		{"remote", []string{"remote", "-v"}, false},
		{"ls-files", []string{"ls-files"}, false},
		{"blame", []string{"blame", "foo.go"}, false},

		// Global flags before subcommand are skipped (legitimate usage).
		{"-C path then allowed", []string{"-C", "/tmp", "log"}, false},
		{"-c kv then allowed", []string{"-c", "color.ui=always", "log"}, false},
		{"--git-dir=path then allowed", []string{"--git-dir=/tmp/.git", "log"}, false},
		{"--work-tree=path then allowed", []string{"--work-tree=/tmp", "status"}, false},
		{"-c then -C then allowed", []string{"-c", "color.ui=always", "-C", "/tmp", "log"}, false},

		// Denied subcommands.
		{"push", []string{"push"}, true},
		{"commit", []string{"commit", "-m", "foo"}, true},
		{"reset", []string{"reset", "--hard", "HEAD"}, true},
		{"checkout", []string{"checkout", "-b", "new"}, true},
		{"rebase", []string{"rebase", "main"}, true},
		{"stash", []string{"stash"}, true},
		{"clone", []string{"clone", "https://example.com/x"}, true},

		// Denied subcommand reached through global-flag skip.
		{"-C path then denied", []string{"-C", "/tmp", "push"}, true},
		{"-c kv then denied", []string{"-c", "color.ui=always", "push"}, true},

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
