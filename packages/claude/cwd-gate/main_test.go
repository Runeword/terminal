package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// standardDirs builds the contains/inside lists for a given $HOME with default
// XDG locations, matching what the launcher passes.
func standardDirs(home string) (contains, inside []string) {
	config := filepath.Join(home, ".config")
	data := filepath.Join(home, ".local", "share")
	contains = []string{home, config, data, filepath.Join(home, ".local")}
	inside = []string{
		filepath.Join(config, "systemd"),
		filepath.Join(config, "autostart"),
		filepath.Join(data, "systemd"),
		filepath.Join(data, "applications"),
		filepath.Join(home, ".local", "bin"),
	}
	return contains, inside
}

func TestCheckGate(t *testing.T) {
	contains, inside := standardDirs("/home/u")
	tests := []struct {
		name        string
		pwd         string
		wantRefused bool
		wantSubstr  string
	}{
		{"project under home allowed", "/home/u/project", false, ""},
		{"nested project allowed", "/home/u/dev/app", false, ""},
		{"config repo like nvim allowed", "/home/u/.config/nvim", false, ""},
		{"tmp allowed", "/tmp/work", false, ""},
		{"home itself refused", "/home/u", true, "it contains /home/u"},
		{"ancestor of home refused", "/home", true, "it contains"},
		{"root refused", "/", true, "it contains"},
		{"xdg config dir refused", "/home/u/.config", true, "it contains"},
		{"local dir refused", "/home/u/.local", true, "it contains"},
		{"systemd user tree refused", "/home/u/.config/systemd/user", true, "it is inside"},
		{"autostart refused", "/home/u/.config/autostart", true, "it is inside"},
		{"applications refused", "/home/u/.local/share/applications/x", true, "it is inside"},
		{"local bin refused", "/home/u/.local/bin", true, "it is inside"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			msg, refused := checkGate(tt.pwd, contains, inside)
			if refused != tt.wantRefused {
				t.Fatalf("checkGate(%q) refused = %v (%q), want %v", tt.pwd, refused, msg, tt.wantRefused)
			}
			if tt.wantSubstr != "" && !strings.Contains(msg, tt.wantSubstr) {
				t.Errorf("checkGate(%q) message = %q, want to contain %q", tt.pwd, msg, tt.wantSubstr)
			}
		})
	}
}

func TestResolveM(t *testing.T) {
	base := t.TempDir()
	real := filepath.Join(base, "real")
	if err := os.MkdirAll(real, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("symlinks unsupported here: %v", err)
	}

	realResolved, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatalf("eval real: %v", err)
	}

	// An existing symlink resolves to its target.
	if got := resolveM(link); got != realResolved {
		t.Errorf("resolveM(link) = %q, want %q", got, realResolved)
	}
	// A non-existent tail is preserved on top of the resolved existing prefix.
	want := filepath.Join(realResolved, "does", "not", "exist")
	if got := resolveM(filepath.Join(link, "does", "not", "exist")); got != want {
		t.Errorf("resolveM(link/does/not/exist) = %q, want %q", got, want)
	}
}
