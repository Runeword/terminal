package main

import (
	"strings"
	"testing"
	"time"
)

func TestClean(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"plain text", "git status", "git status"},
		{"unicode kept", "café ✓ résumé", "café ✓ résumé"},
		{"strips ESC so CSI colour is inert", "a\x1b[31mred\x1b[0mb", "a[31mred[0mb"},
		{"strips OSC 52 clipboard write", "x\x1b]52;c;ZXZpbA==\x07y", "x]52;c;ZXZpbA==y"},
		{"strips title-spoof OSC", "\x1b]0;PWNED\x07ok", "]0;PWNEDok"},
		{"strips DEL and other C0", "a\x7f\x00\x08b", "ab"},
		{"strips CR and LF", "a\r\nb", "ab"},
		{"strips C1 CSI", "axb", "axb"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := clean(tt.in)
			if got != tt.want {
				t.Errorf("clean(%q) = %q, want %q", tt.in, got, tt.want)
			}
			// No byte that can begin/terminate an escape sequence survives.
			for _, r := range got {
				if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
					t.Errorf("clean(%q) left a control rune %#x", tt.in, r)
				}
			}
		})
	}
}

func TestFormatLineStripsInjectedEscapes(t *testing.T) {
	// Detail carries a truncated, attacker-influenceable Bash command. formatLine
	// adds its own CSI colour codes (\x1b[…), so we can't assert "no ESC at all";
	// instead assert the OSC form (\x1b]) and its BEL terminator never survive.
	st := State{State: "tool", Cwd: "/proj", Model: "m", Detail: "\x1b]0;pwn\x07x"}
	out := formatLine(st, time.Now().Unix())
	if strings.Contains(out, "\x1b]") || strings.Contains(out, "\x07") {
		t.Errorf("formatLine leaked an escape from Detail: %q", out)
	}
}

func TestToolDetail(t *testing.T) {
	mk := func(tool, cmd, fp string) hookInput {
		var in hookInput
		in.ToolName = tool
		in.ToolInput.Command = cmd
		in.ToolInput.FilePath = fp
		return in
	}
	tests := []struct {
		name string
		in   hookInput
		want string
	}{
		{"bash first line only", mk("Bash", "git status\nrm -rf /", ""), "Bash: git status"},
		{"edit shows basename", mk("Edit", "", "/a/b/file.go"), "Edit: file.go"},
		{"read shows basename", mk("Read", "", "/x/y/main.rs"), "Read: main.rs"},
		{"unknown tool falls back to name", mk("Grep", "", ""), "Grep"},
		{"no tool", mk("", "", ""), "tool"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := toolDetail(tt.in); got != tt.want {
				t.Errorf("toolDetail() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestTruncate(t *testing.T) {
	if got := truncate("abcdef", 4); got != "abc…" {
		t.Errorf("truncate = %q, want %q", got, "abc…")
	}
	if got := truncate("abc", 4); got != "abc" {
		t.Errorf("truncate should not alter short input, got %q", got)
	}
	// Rune-aware: must not split a multi-byte rune.
	if got := truncate("héllo", 3); got != "hé…" {
		t.Errorf("truncate = %q, want %q", got, "hé…")
	}
}
