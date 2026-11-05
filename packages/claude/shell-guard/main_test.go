package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func TestProtectedDirs(t *testing.T) {
	home := tempDir(t)
	mkdirs(t, home, ".claude-1/projects/p/memory", ".claude-vm-1", "repo")
	touch(t, home, ".claude.json")
	link(t, filepath.Join(home, ".claude-1"), filepath.Join(home, ".claude-link"))
	got := protectedDirs(home, "/srv/cfg")
	want := []string{
		"/srv/cfg/projects",
		filepath.Join(home, ".claude", "projects"),
		filepath.Join(home, ".claude-1", "projects"),
		filepath.Join(home, ".claude-vm-1", "projects"),
	}
	sort.Strings(want)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("protectedDirs = %q, want %q", got, want)
	}
}

func TestPlan(t *testing.T) {
	home := tempDir(t)
	mkdirs(t, home, ".claude-1/projects/p/memory", ".claude-1/open-sessions", "repo")
	touch(t, home, ".claude-1/settings.json", ".claude.json")
	link(t, filepath.Join(home, ".claude-1/projects/p/memory"), filepath.Join(home, "memory-link"))
	granted := make(map[string]bool) // path → dir
	for _, g := range plan(protectedDirs(home, "")) {
		granted[g.path] = g.dir
	}
	tests := []struct {
		name    string
		path    string
		granted bool
		dir     bool
	}{
		{"a folder in home", "repo", true, true},
		{"a file in home", ".claude.json", true, false},
		{"a folder in the profile", ".claude-1/open-sessions", true, true},
		{"a file in the profile", ".claude-1/settings.json", true, false},
		{"home itself", "", false, false},
		{"the profile itself", ".claude-1", false, false},
		{"its projects folder", ".claude-1/projects", false, false},
		{"a project", ".claude-1/projects/p", false, false},
		{"a link to memory", "memory-link", false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir, ok := granted[filepath.Join(home, tt.path)]
			if ok != tt.granted || dir != tt.dir {
				t.Errorf("granted = %v (folder %v), want %v (folder %v)", ok, dir, tt.granted, tt.dir)
			}
		})
	}
}

func TestShellPath(t *testing.T) {
	bin := tempDir(t)
	for _, name := range []string{"zsh", "bash", "fish"} {
		if err := os.WriteFile(filepath.Join(bin, name), nil, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	tests := []struct {
		name     string
		override string
		login    string
		want     string
	}{
		{"the override first", bin + "/bash", bin + "/zsh", "bash"},
		{"then the login shell", "", bin + "/zsh", "zsh"},
		{"an override that is neither bash nor zsh", bin + "/fish", bin + "/bash", "bash"},
		{"a login shell that is neither: zsh first", "", bin + "/fish", "zsh"},
		{"a login bash that is gone: bash first", "", "/gone/bash", "bash"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := shellPath(tt.override, tt.login)
			if err != nil || got != filepath.Join(bin, tt.want) {
				t.Errorf("shellPath = %q, %v; want %q", got, err, filepath.Join(bin, tt.want))
			}
		})
	}
}

// tempDir is a test's temporary folder with symbolic links resolved, as
// protectedDirs and plan resolve them (macOS's /var is a link).
func tempDir(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func mkdirs(t *testing.T, root string, dirs ...string) {
	t.Helper()
	for _, d := range dirs {
		if err := os.MkdirAll(filepath.Join(root, d), 0o700); err != nil {
			t.Fatal(err)
		}
	}
}

func touch(t *testing.T, root string, files ...string) {
	t.Helper()
	for _, f := range files {
		if err := os.WriteFile(filepath.Join(root, f), []byte("x\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func link(t *testing.T, target, name string) {
	t.Helper()
	if err := os.Symlink(target, name); err != nil {
		t.Fatal(err)
	}
}
