package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestDigestDropsOwnEntries(t *testing.T) {
	// Self-echo is the failure that makes a shared journal useless: a session
	// re-reading its own notes wastes context and invites it to reply to itself.
	es := []entry{
		{Session: "me", Label: "a/1111", Kind: "note", Text: "mine"},
		{Session: "peer", Label: "b/2222", Kind: "note", Text: "theirs"},
	}
	got := digest("refactor", "me", es)
	if strings.Contains(got, "mine") {
		t.Errorf("digest echoed the reader's own entry:\n%s", got)
	}
	if !strings.Contains(got, "theirs") {
		t.Errorf("digest dropped a peer entry:\n%s", got)
	}
}

func TestDigestEmptyWhenNothingToShow(t *testing.T) {
	tests := []struct {
		name string
		es   []entry
	}{
		{"no entries", nil},
		{"only own entries", []entry{{Session: "me", Kind: "note", Text: "x"}}},
		{"blank note", []entry{{Session: "peer", Kind: "note", Text: "   "}}},
		{"unknown kind", []entry{{Session: "peer", Kind: "wat"}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := digest("g", "me", tt.es); got != "" {
				t.Errorf("digest = %q, want empty (a quiet prompt must cost no context)", got)
			}
		})
	}
}

func TestDigestCoalescesConsecutiveEdits(t *testing.T) {
	es := []entry{
		{Session: "peer", Label: "b/2222", Kind: "edit", Path: "a.go"},
		{Session: "peer", Label: "b/2222", Kind: "edit", Path: "b.go"},
		{Session: "peer", Label: "b/2222", Kind: "edit", Path: "c.go"},
		{Session: "peer", Label: "b/2222", Kind: "edit", Path: "d.go"},
	}
	got := digest("g", "me", es)
	if n := strings.Count(got, "\n- "); n != 1 {
		t.Errorf("got %d rows, want 1 coalesced row:\n%s", n, got)
	}
	if !strings.Contains(got, "edited 4 files") {
		t.Errorf("digest lost the edit count:\n%s", got)
	}
}

func TestDigestKeepsRunsSeparate(t *testing.T) {
	// A note between two edit runs must not merge them, or the ordering lies.
	es := []entry{
		{Session: "peer", Label: "b", Kind: "edit", Path: "a.go"},
		{Session: "peer", Label: "b", Kind: "note", Text: "switching files"},
		{Session: "peer", Label: "b", Kind: "edit", Path: "z.go"},
	}
	got := digest("g", "me", es)
	if n := strings.Count(got, "\n- "); n != 3 {
		t.Errorf("got %d rows, want 3:\n%s", n, got)
	}
}

func TestEditSummary(t *testing.T) {
	tests := []struct {
		name  string
		files []string
		want  string
	}{
		{"none", nil, "edited files"},
		{"one", []string{"main.go"}, "edited main.go"},
		{"basename only", []string{"/deep/nested/path/main.go"}, "edited main.go"},
		{"three named", []string{"a.go", "b.go", "c.go"}, "edited a.go, b.go, c.go"},
		{"counts past three", []string{"a", "b", "c", "d"}, "edited 4 files (a, b, c, …)"},
		{"dedupes repeats", []string{"a.go", "a.go", "a.go"}, "edited a.go"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := editSummary(tt.files); got != tt.want {
				t.Errorf("editSummary(%v) = %q, want %q", tt.files, got, tt.want)
			}
		})
	}
}

func TestDigestCapsVolume(t *testing.T) {
	// A session returning after a long absence must not have its context
	// window flooded by the backlog.
	var es []entry
	for i := 0; i < 500; i++ {
		es = append(es, entry{
			Session: "peer",
			Label:   fmt.Sprintf("p%d", i), // distinct labels defeat coalescing
			Kind:    "note",
			Text:    strings.Repeat("x", 60),
		})
	}
	got := digest("g", "me", es)

	if len(got) > maxDigestBytes {
		t.Errorf("digest is %d bytes, want <= %d", len(got), maxDigestBytes)
	}
	if n := strings.Count(got, "\n- "); n > maxDigestEntries {
		t.Errorf("digest has %d rows, want <= %d", n, maxDigestEntries)
	}
	if !strings.Contains(got, "older entries omitted") {
		t.Errorf("truncation was silent; the reader cannot tell it missed entries:\n%s", got)
	}
	// The newest entries are the ones worth keeping.
	if !strings.Contains(got, "p499") {
		t.Errorf("digest dropped the newest entry:\n%s", got)
	}
}

func TestCleanStripsControlBytes(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"plain", "hello world", "hello world"},
		{"osc52 clipboard write", "a\x1b]52;c;ZXZpbA==\x07b", "a]52;c;ZXZpbA==b"},
		{"cursor drive", "a\x1b[2Jb", "a[2Jb"},
		{"newline flattened", "one\ntwo", "onetwo"},
		{"del", "a\x7fb", "ab"},
		{"c1 range", "a\u0085b", "ab"},
		{"unicode kept", "café ✓", "café ✓"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := clean(tt.in)
			if got != tt.want {
				t.Errorf("clean(%q) = %q, want %q", tt.in, got, tt.want)
			}
			if strings.ContainsRune(got, 0x1b) {
				t.Errorf("clean(%q) left an ESC byte", tt.in)
			}
		})
	}
}

func TestDigestSanitizesModelAuthoredText(t *testing.T) {
	// Note text and labels reach both another model's context and a terminal
	// via `log`, so escapes must not survive the round trip.
	es := []entry{{Session: "peer", Label: "b\x1b[31m", Kind: "note", Text: "x\x1b]52;c;e\x07"}}
	if got := digest("g", "me", es); strings.ContainsRune(got, 0x1b) {
		t.Errorf("digest passed an escape sequence through:\n%q", got)
	}
}

func TestRelPath(t *testing.T) {
	tests := []struct {
		name, cwd, path, want string
	}{
		{"inside cwd", "/home/c/terminal", "/home/c/terminal/pkg/main.go", "pkg/main.go"},
		{"outside cwd stays absolute", "/home/c/terminal", "/etc/hosts", "/etc/hosts"},
		{"no cwd", "", "/etc/hosts", "/etc/hosts"},
		{"no path", "/home/c", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := relPath(tt.cwd, tt.path); got != tt.want {
				t.Errorf("relPath(%q, %q) = %q, want %q", tt.cwd, tt.path, got, tt.want)
			}
		})
	}
}

func TestProtocolStatesGroupAndPeers(t *testing.T) {
	got := protocol("refactor", []peer{{Label: "nixos/9b1c", Cwd: "/home/c/nixos"}})
	for _, want := range []string{"refactor", "nixos/9b1c", "claude-context note"} {
		if !strings.Contains(got, want) {
			t.Errorf("protocol block missing %q:\n%s", want, got)
		}
	}

	alone := protocol("refactor", nil)
	if !strings.Contains(alone, "No other sessions") {
		t.Errorf("protocol block should say when the group is empty:\n%s", alone)
	}
}
