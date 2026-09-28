package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func testStore(t *testing.T) *store {
	t.Helper()
	s := openAt(t.TempDir(), "refactor")
	if s == nil {
		t.Fatal("openAt returned nil for a valid group")
	}
	return s
}

func TestValidGroup(t *testing.T) {
	tests := []struct {
		name  string
		group string
		want  bool
	}{
		{"simple", "refactor", true},
		{"digits and dashes", "fix-142_v2", true},
		{"dotted", "web.api", true},
		{"empty", "", false},
		{"dot", ".", false},
		{"dotdot", "..", false},
		{"traversal", "../../etc", false},
		{"slash", "a/b", false},
		{"space", "my group", false},
		{"nul", "a\x00b", false},
		{"too long", strings.Repeat("a", 65), false},
		{"max length", strings.Repeat("a", 64), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := validGroup(tt.group); got != tt.want {
				t.Errorf("validGroup(%q) = %v, want %v", tt.group, got, tt.want)
			}
			// An invalid group must never yield a usable store: the name
			// becomes a path component under $CLAUDE_CONFIG_DIR.
			if got := openAt("/tmp/root", tt.group) != nil; got != tt.want {
				t.Errorf("openAt(%q) usable = %v, want %v", tt.group, got, tt.want)
			}
		})
	}
}

func TestConfigDirFallsBackToDefaultInstance(t *testing.T) {
	// `log` and `peers` are typed into an interactive shell, which does not
	// export CLAUDE_CONFIG_DIR. Reading ~/.claude instead of ~/.claude-1 there
	// would show an empty journal and look like the feature was broken.
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")

	if got, want := configDir(), filepath.Join(home, ".claude"); got != want {
		t.Errorf("with no instance dir: configDir() = %q, want %q", got, want)
	}

	inst := filepath.Join(home, ".claude-1")
	if err := os.MkdirAll(inst, 0o700); err != nil {
		t.Fatal(err)
	}
	if got := configDir(); got != inst {
		t.Errorf("configDir() = %q, want the default instance %q", got, inst)
	}

	t.Setenv("CLAUDE_CONFIG_DIR", "/explicit")
	if got := configDir(); got != "/explicit" {
		t.Errorf("configDir() = %q, want the environment to win", got)
	}
}

func TestOpenAtRejectsEmptyRoot(t *testing.T) {
	if openAt("", "refactor") != nil {
		t.Error("openAt with no config root should return nil")
	}
}

func TestJournalRoundTrip(t *testing.T) {
	s := testStore(t)
	want := entry{TS: 42, Session: "s1", Label: "terminal/aaaa", Kind: "note", Text: "hello"}
	if err := s.append(want); err != nil {
		t.Fatalf("append: %v", err)
	}

	es, next, err := s.readSince(0)
	if err != nil {
		t.Fatalf("readSince: %v", err)
	}
	if len(es) != 1 {
		t.Fatalf("got %d entries, want 1", len(es))
	}
	if es[0] != want {
		t.Errorf("got %+v, want %+v", es[0], want)
	}
	if next == 0 {
		t.Error("offset should advance past the written entry")
	}
}

func TestReadSinceIsIncremental(t *testing.T) {
	s := testStore(t)
	if err := s.append(entry{Session: "s1", Kind: "note", Text: "first"}); err != nil {
		t.Fatal(err)
	}

	_, off, err := s.readSince(0)
	if err != nil {
		t.Fatal(err)
	}

	// Nothing new: the whole point is that a quiet prompt costs zero context.
	es, off2, err := s.readSince(off)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 0 {
		t.Fatalf("got %d entries from an unchanged journal, want 0", len(es))
	}
	if off2 != off {
		t.Errorf("offset moved without new data: %d -> %d", off, off2)
	}

	if err := s.append(entry{Session: "s2", Kind: "note", Text: "second"}); err != nil {
		t.Fatal(err)
	}
	es, _, err = s.readSince(off2)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 1 || es[0].Text != "second" {
		t.Fatalf("got %+v, want only the new entry", es)
	}
}

func TestReadSinceResetsStaleOffset(t *testing.T) {
	// An offset past EOF means the journal rotated. Re-delivering once beats
	// going permanently silent.
	s := testStore(t)
	if err := s.append(entry{Session: "s1", Kind: "note", Text: "only"}); err != nil {
		t.Fatal(err)
	}
	es, _, err := s.readSince(1 << 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 1 {
		t.Fatalf("got %d entries, want 1 after offset reset", len(es))
	}
}

func TestReadSinceMissingJournal(t *testing.T) {
	s := testStore(t)
	es, next, err := s.readSince(500)
	if err != nil {
		t.Fatalf("readSince on a missing journal should not error: %v", err)
	}
	if len(es) != 0 || next != 0 {
		t.Errorf("got %d entries at offset %d, want 0 at 0", len(es), next)
	}
}

func TestReadSinceIgnoresPartialAndCorruptLines(t *testing.T) {
	s := testStore(t)
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		t.Fatal(err)
	}
	// A good line, a corrupt one, then a trailing line with no newline.
	body := `{"session":"s1","kind":"note","text":"good"}` + "\n" +
		"{not json at all}\n" +
		`{"session":"s1","kind":"note","text":"torn"}`
	if err := os.WriteFile(s.journalPath(), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	es, next, err := s.readSince(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != 1 || es[0].Text != "good" {
		t.Fatalf("got %+v, want only the well-formed complete line", es)
	}
	// The torn line must stay unconsumed so it is delivered once finished.
	if int(next) >= len(body) {
		t.Errorf("offset %d consumed the incomplete trailing line (len %d)", next, len(body))
	}
}

func TestCursorPersistsAndDefaults(t *testing.T) {
	s := testStore(t)
	if got := s.cursor("s1"); got != 0 {
		t.Errorf("unset cursor = %d, want 0", got)
	}
	s.setCursor("s1", 128)
	if got := s.cursor("s1"); got != 128 {
		t.Errorf("cursor = %d, want 128", got)
	}
	// A corrupt cursor restarts from the top rather than failing the hook.
	if err := os.WriteFile(s.cursorPath("s1"), []byte("garbage"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := s.cursor("s1"); got != 0 {
		t.Errorf("corrupt cursor = %d, want 0", got)
	}
}

func TestPeersExcludesSelfAndStale(t *testing.T) {
	s := testStore(t)
	now := time.Now()

	s.touch(peer{Session: "self", Label: "me", Cwd: "/a"})
	s.touch(peer{Session: "live", Label: "peer-live", Cwd: "/b"})

	// A record older than the presence window, written directly so it is stale
	// regardless of how fast the test runs.
	stale := peer{Session: "dead", Label: "peer-dead", Updated: now.Add(-time.Hour).Unix()}
	b, err := json.Marshal(stale)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(s.peerPath("dead"), b, 0o600); err != nil {
		t.Fatal(err)
	}

	got := s.peers("self", now)
	if len(got) != 1 || got[0].Session != "live" {
		t.Fatalf("peers = %+v, want only the live peer", got)
	}
	if _, err := os.Stat(s.peerPath("dead")); !os.IsNotExist(err) {
		t.Error("stale peer record should be pruned")
	}
}

func TestSelfPeerSuppliesStableLabel(t *testing.T) {
	// `note` runs from wherever the model last cd'd to, so it must take its
	// label from the roster the hooks wrote rather than from its own cwd —
	// otherwise one session's notes and edits appear under different names.
	s := testStore(t)
	if _, ok := s.selfPeer("s1"); ok {
		t.Error("selfPeer should report missing before any hook has run")
	}

	s.touch(peer{Session: "s1", Label: "terminal/aaaa", Cwd: "/home/c/terminal"})
	got, ok := s.selfPeer("s1")
	if !ok {
		t.Fatal("selfPeer should find the record the hook wrote")
	}
	if got.Label != "terminal/aaaa" {
		t.Errorf("label = %q, want %q", got.Label, "terminal/aaaa")
	}

	// A corrupt record falls back rather than returning a blank label.
	if err := os.WriteFile(s.peerPath("s2"), []byte("{bad"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.selfPeer("s2"); ok {
		t.Error("selfPeer should reject a corrupt record")
	}
}

func TestDropRemovesSessionState(t *testing.T) {
	s := testStore(t)
	s.touch(peer{Session: "s1", Label: "l"})
	s.setCursor("s1", 10)
	s.drop("s1")

	if _, err := os.Stat(s.peerPath("s1")); !os.IsNotExist(err) {
		t.Error("peer record should be gone")
	}
	if got := s.cursor("s1"); got != 0 {
		t.Errorf("cursor = %d after drop, want 0", got)
	}
}

func TestConcurrentAppend(t *testing.T) {
	// Several sessions append at once in normal use; run with -race.
	s := testStore(t)
	const writers, each = 8, 12

	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < each; i++ {
				if err := s.append(entry{Session: "s", Kind: "note", Text: "x"}); err != nil {
					t.Errorf("append: %v", err)
					return
				}
			}
		}(w)
	}
	wg.Wait()

	es, _, err := s.readSince(0)
	if err != nil {
		t.Fatal(err)
	}
	if len(es) != writers*each {
		t.Errorf("got %d entries, want %d — interleaved writes were lost or torn",
			len(es), writers*each)
	}
}

func TestLabelFor(t *testing.T) {
	t.Setenv("CLAUDE_CONTEXT_LABEL", "")
	tests := []struct {
		name, cwd, id, want string
	}{
		{"repo and short id", "/home/c/terminal", "2ee07d5c-0f44", "terminal/2ee0"},
		{"trailing slash", "/home/c/nixos/", "abcdef", "nixos/abcd"},
		{"short id kept whole", "/tmp/x", "ab", "x/ab"},
		{"no id", "/tmp/x", "", "x"},
		{"root cwd", "/", "abcdef", "session/abcd"},
		{"empty cwd", "", "abcdef", "session/abcd"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := labelFor(tt.cwd, tt.id); got != tt.want {
				t.Errorf("labelFor(%q, %q) = %q, want %q", tt.cwd, tt.id, got, tt.want)
			}
		})
	}
}

func TestLabelForEnvOverride(t *testing.T) {
	t.Setenv("CLAUDE_CONTEXT_LABEL", "reviewer")
	if got := labelFor("/home/c/terminal", "abcdef"); got != "reviewer" {
		t.Errorf("labelFor = %q, want the CLAUDE_CONTEXT_LABEL override", got)
	}
}

func TestSanitizeKeepsPathsFlat(t *testing.T) {
	tests := []struct{ in, want string }{
		{"2ee07d5c-0f44-4f29", "2ee07d5c-0f44-4f29"},
		{"../../escape", "______escape"},
		{"a/b", "a_b"},
		{"", "_"},
	}
	for _, tt := range tests {
		if got := sanitize(tt.in); got != tt.want {
			t.Errorf("sanitize(%q) = %q, want %q", tt.in, got, tt.want)
		}
		if strings.ContainsAny(sanitize(tt.in), `/\`) {
			t.Errorf("sanitize(%q) leaked a path separator", tt.in)
		}
	}
}

func TestStorePathsStayInsideGroupDir(t *testing.T) {
	s := testStore(t)
	for _, p := range []string{s.journalPath(), s.cursorPath("../x"), s.peerPath("../x")} {
		if !strings.HasPrefix(filepath.Clean(p), filepath.Clean(s.dir)) {
			t.Errorf("path %q escaped the group directory %q", p, s.dir)
		}
	}
}
