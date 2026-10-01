package main

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	idA = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
	idB = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
	idC = "cccccccc-3333-4333-8333-cccccccccccc"
)

// write creates path, and the directories above it, holding lines.
func write(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDirName(t *testing.T) {
	tests := []struct{ in, want string }{
		{"/home/charles/terminal", "-home-charles-terminal"},
		{"/tmp/a_b.c d", "-tmp-a-b-c-d"},
		{"/x/café", "-x-caf-"},
	}
	for _, tt := range tests {
		if got := dirName(tt.in); got != tt.want {
			t.Errorf("dirName(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestProjectDir(t *testing.T) {
	cfg := t.TempDir()
	short := filepath.Join(cfg, "projects", "-work-repo")
	long := "/" + strings.Repeat("a", 250)
	hashed := filepath.Join(cfg, "projects", dirName(long)[:maxDirName]+"-1x2y3z")
	for _, d := range []string{short, hashed} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	tests := []struct{ cwd, want string }{
		{"/work/repo", short},
		{"/work/other", ""},
		{long, hashed}, // the hash differs between builds: matched on the prefix
	}
	for _, tt := range tests {
		if got := projectDir(cfg, tt.cwd); got != tt.want {
			t.Errorf("projectDir(%q) = %q, want %q", tt.cwd, got, tt.want)
		}
	}
}

func TestFields(t *testing.T) {
	tests := []struct{ name, in, first, last string }{
		{"first and last", `{"k":"a"} {"k":"b"}`, "a", "b"},
		{"spaced and compact forms in order", `{"k": "a"} {"k":"b"}`, "a", "b"},
		{"escapes", `{"k":"say \"hi\" caf\u00e9"}`, `say "hi" café`, `say "hi" café`},
		{"key quoted inside another string", `{"t":"{\"k\":\"no\"}"}`, "", ""},
		{"key ending another key", `{"xk":"no","k":"yes"}`, "yes", "yes"},
		{"value cut off", `{"k":"abc`, "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := firstField([]byte(tt.in), "k"); got != tt.first {
				t.Errorf("firstField = %q, want %q", got, tt.first)
			}
			if got := lastField([]byte(tt.in), "k"); got != tt.last {
				t.Errorf("lastField = %q, want %q", got, tt.last)
			}
		})
	}
}

func TestFirstPrompt(t *testing.T) {
	tests := []struct {
		name  string
		lines []string
		want  string
	}{
		{"skips meta, tool results and command output", []string{
			`{"type":"permission-mode","permissionMode":"auto"}`,
			`{"type":"user","isMeta":true,"message":{"content":"meta"}}`,
			`{"type":"user","message":{"content":[{"type":"tool_result","content":"out"}]}}`,
			`{"type":"user","message":{"content":"<local-command-stdout>ok</local-command-stdout>"}}`,
			`{"type":"user","message":{"content":[{"type":"text","text":"fix the\nbug"}]}}`,
		}, "fix the bug"},
		{"a command stands in when nothing was typed", []string{
			`{"type":"user","message":{"content":"<command-name>/init</command-name>"}}`,
		}, "/init"},
		{"a typed prompt beats an earlier command", []string{
			`{"type":"user","message":{"content":"<command-name>/init</command-name>"}}`,
			`{"type":"user","message":{"content":"then this"}}`,
		}, "then this"},
		{"a long prompt is cut", []string{
			`{"type":"user","message":{"content":"` + strings.Repeat("x", 300) + `"}}`,
		}, strings.Repeat("x", maxPrompt-1) + "…"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := firstPrompt([]byte(strings.Join(tt.lines, "\n"))); got != tt.want {
				t.Errorf("firstPrompt = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParse(t *testing.T) {
	tests := []struct {
		name, head, tail string // no tail: the file fits in one read
		title, branch    string // no title: the session is left out
	}{
		{"a name beats the generated title", `{"aiTitle":"AI"}` + "\n" + `{"customTitle":"mine"}`, "", "mine", "-"},
		{"the last generated title", `{"aiTitle":"one"}` + "\n" + `{"aiTitle":"two"}`, "", "two", "-"},
		{"the tail beats the head", `{"aiTitle":"old"}`, `{"aiTitle":"new"}`, "new", "-"},
		{"a name in the head beats a title in the tail", `{"customTitle":"mine"}`, `{"aiTitle":"new"}`, "mine", "-"},
		{"the last prompt without a title", `{"type":"user","message":{"content":"first"}}`, `{"lastPrompt":"latest"}`, "latest", "-"},
		{"the first prompt as a last resort", `{"type":"user","gitBranch":"main","message":{"content":"hello"}}`, "", "hello", "main"},
		{"the branch at the end", `{"gitBranch":"a"}` + "\n" + `{"aiTitle":"t"}`, `{"gitBranch":"b"}`, "t", "b"},
		{"control characters cleaned", `{"aiTitle":"a\tb\u001b]0;x\u0007c"}`, "", "a b ]0;x c", "-"},
		{"a sidechain is left out", `{"isSidechain":true,"aiTitle":"t"}`, "", "", ""},
		{"a claude -p run is left out", `{"type":"user","entrypoint":"sdk-cli","message":{"content":"hi"}}`, "", "", ""},
		{"metadata only is left out", `{"type":"permission-mode","permissionMode":"auto"}`, "", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			l := lite{head: []byte(tt.head), tail: []byte(tt.tail)}
			if tt.tail == "" {
				l.tail = l.head
			}
			s, ok := parse(idA, l)
			if ok != (tt.title != "") || s.title != tt.title || ok && s.branch != tt.branch {
				t.Errorf("parse = %q %q %v, want %q %q", s.title, s.branch, ok, tt.title, tt.branch)
			}
		})
	}
}

func TestReadLite(t *testing.T) {
	// The title is written past the first 64 KiB: only the tail read sees it.
	path := filepath.Join(t.TempDir(), idA+".jsonl")
	write(t, path,
		`{"type":"user","message":{"content":"first"}}`,
		`{"type":"assistant","message":{"content":"`+strings.Repeat("z", 2*liteBuf)+`"}}`,
		`{"type":"ai-title","aiTitle":"late"}`)
	l, err := readLite(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(l.head) != liteBuf || len(l.tail) != liteBuf {
		t.Fatalf("read %d+%d bytes, want %d each", len(l.head), len(l.tail), liteBuf)
	}
	if s, ok := parse(idA, l); !ok || s.title != "late" {
		t.Errorf("parse = %q %v, want the title from the tail", s.title, ok)
	}
}

func TestList(t *testing.T) {
	cfg, cwd := t.TempDir(), t.TempDir()
	real, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		t.Fatal(err)
	}
	proj := filepath.Join(cfg, "projects", dirName(real))
	now := time.Now()
	sessions := []struct {
		name  string
		age   time.Duration
		lines []string
	}{
		{idA + ".jsonl", 2 * time.Hour, []string{`{"type":"user","entrypoint":"cli","gitBranch":"main","message":{"content":"a"}}`, `{"aiTitle":"Alpha"}`}},
		{idB + ".jsonl", 5 * time.Minute, []string{`{"type":"user","entrypoint":"cli","gitBranch":"feature/x","message":{"content":"b"}}`, `{"aiTitle":"Beta"}`}},
		{idC + ".jsonl", time.Minute, []string{`{"type":"user","entrypoint":"sdk-cli","message":{"content":"c"}}`}},
		{"notes.jsonl", time.Minute, []string{`{"aiTitle":"not a session"}`}},
	}
	for _, s := range sessions {
		path := filepath.Join(proj, s.name)
		write(t, path, s.lines...)
		if err := os.Chtimes(path, now.Add(-s.age), now.Add(-s.age)); err != nil {
			t.Fatal(err)
		}
	}
	var out bytes.Buffer
	if err := list(&out, cfg, cwd, now); err != nil {
		t.Fatal(err)
	}
	want := idB + "\t5m    feature/x  Beta\n" +
		idA + "\t2h    main       Alpha\n"
	if out.String() != want {
		t.Errorf("list =\n%s\nwant\n%s", out.String(), want)
	}

	out.Reset()
	if err := list(&out, cfg, t.TempDir(), now); err != nil || out.Len() != 0 {
		t.Errorf("list of a directory without sessions = %q, %v", out.String(), err)
	}
}

func TestAge(t *testing.T) {
	tests := []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Second, "now"},
		{-time.Hour, "now"},
		{5 * time.Minute, "5m"},
		{3 * time.Hour, "3h"},
		{50 * time.Hour, "2d"},
		{120 * 24 * time.Hour, "17w"},
	}
	for _, tt := range tests {
		if got := age(tt.d); got != tt.want {
			t.Errorf("age(%v) = %q, want %q", tt.d, got, tt.want)
		}
	}
}

func TestCut(t *testing.T) {
	tests := []struct {
		in   string
		n    int
		want string
	}{
		{"abc", 5, "abc"},
		{"abcdef", 4, "abc…"},
		{"ab cdef", 4, "ab…"},
		{"héllo wörld", 6, "héllo…"},
	}
	for _, tt := range tests {
		if got := cut(tt.in, tt.n); got != tt.want {
			t.Errorf("cut(%q, %d) = %q, want %q", tt.in, tt.n, got, tt.want)
		}
	}
}

func TestPreview(t *testing.T) {
	cfg := t.TempDir()
	write(t, filepath.Join(cfg, "projects", "-p", idA+".jsonl"),
		`{"type":"user","message":{"content":"fix it"}}`,
		`{"type":"user","isMeta":true,"message":{"content":"meta text"}}`,
		`{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash"}]}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","content":"tool output"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Read"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Grep"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"x\u001b]52;c;eA==\u0007done"}]}}`,
		`{"type":"user","message":{"content":"<command-name>/compact</command-name>\n<command-args>keep tests</command-args>"}}`,
		`{"type":"ai-title","aiTitle":"Fixing"}`)
	var out bytes.Buffer
	if err := preview(&out, cfg, idA, time.Now()); err != nil {
		t.Fatal(err)
	}
	got := out.String()
	for _, want := range []string{
		bold + "Fixing" + reset, bold + "❯ fix it" + reset, "On it.",
		"· Bash" + reset, "· Read ×3" + reset + "\n" + dim + "· Grep" + reset,
		"x]52;c;eA==done", "❯ /compact keep tests",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("preview lacks %q:\n%s", want, got)
		}
	}
	for _, unwanted := range []string{"meta text", "hmm", "tool output", "\x1b]", "\x07"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("preview shows %q:\n%s", unwanted, got)
		}
	}
}

func TestRm(t *testing.T) {
	cfg := t.TempDir()
	proj := filepath.Join(cfg, "projects", "-p")
	write(t, filepath.Join(proj, idA+".jsonl"),
		`{"type":"user","sessionId":"`+idA+`","slug":"only-a","message":{"content":"hi"}}`,
		`{"type":"user","sessionId":"`+idA+`","slug":"shared","message":{"content":"again"}}`)
	// B was branched from A: it names the same plan, and shares a paste.
	write(t, filepath.Join(proj, idB+".jsonl"),
		`{"type":"user","sessionId":"`+idB+`","slug":"shared","message":{"content":"hi"}}`)
	files := map[string]bool{ // whether each is still there afterwards
		filepath.Join(proj, idA, "subagents", "agent-x.jsonl"): false,
		filepath.Join(cfg, "file-history", idA, "f@v1"):        false,
		filepath.Join(cfg, "session-env", idA, "hook-0.sh"):    false,
		filepath.Join(cfg, "debug", idA+".txt"):                false,
		filepath.Join(cfg, "plans", "only-a.md"):               false,
		filepath.Join(cfg, "plans", "shared.md"):               true,
		filepath.Join(cfg, "paste-cache", "aa11.txt"):          false,
		filepath.Join(cfg, "paste-cache", "bb22.txt"):          true,
		filepath.Join(cfg, "file-history", idB, "f@v1"):        true,
	}
	for f := range files {
		write(t, f, "x")
	}
	// B's prompt quotes A's id, which must not count as one of A's.
	lineB := `{"display":"see \"sessionId\":\"` + idA + `\"","pastedContents":{"1":{"id":1,"type":"text","contentHash":"bb22"}},"sessionId":"` + idB + `"}` + "\n"
	history := filepath.Join(cfg, "history.jsonl")
	if err := os.WriteFile(history, []byte(
		`{"display":"one","pastedContents":{"1":{"id":1,"type":"text","contentHash":"aa11"},"2":{"id":2,"type":"text","contentHash":"bb22"}},"sessionId":"`+idA+`"}`+"\n"+
			lineB+
			`{"display":"two","pastedContents":{},"sessionId":"`+idA+`"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := rm(&out, strings.NewReader(""), cfg, idA, false, time.Now()); err != nil {
		t.Fatal(err)
	}
	want := "erased " + idA + ": transcript, subagents and tool results, file history, hook env, debug log, 2 prompts, 1 paste, 1 plan\n"
	if out.String() != want {
		t.Errorf("rm said %q, want %q", out.String(), want)
	}
	for _, path := range []string{filepath.Join(proj, idA+".jsonl"), filepath.Join(proj, idA)} {
		if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("%s survived", path)
		}
	}
	files[filepath.Join(proj, idB+".jsonl")] = true
	for f, kept := range files {
		if _, err := os.Stat(f); kept != (err == nil) {
			t.Errorf("%s: kept = %v, want %v", f, err == nil, kept)
		}
	}
	got, err := os.ReadFile(history)
	if err != nil || string(got) != lineB {
		t.Errorf("history.jsonl = %q, %v, want only B's line", got, err)
	}
	st, err := os.Stat(history)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Errorf("history.jsonl mode = %v, want 0600", st.Mode().Perm())
	}
}

func TestRmAsk(t *testing.T) {
	tests := []struct {
		answer string
		erased bool
	}{{"n\n", false}, {"\n", false}, {"", false}, {"y\n", true}, {"YES\n", true}}
	for _, tt := range tests {
		cfg := t.TempDir()
		path := filepath.Join(cfg, "projects", "-p", idA+".jsonl")
		write(t, path, `{"type":"ai-title","aiTitle":"Alpha"}`)
		var out bytes.Buffer
		if err := rm(&out, strings.NewReader(tt.answer), cfg, idA, true, time.Now()); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(path); tt.erased != errors.Is(err, fs.ErrNotExist) {
			t.Errorf("answer %q: erased = %v, want %v", tt.answer, !tt.erased, tt.erased)
		}
		if !strings.HasPrefix(out.String(), `Erase "Alpha" (active just now)?`) {
			t.Errorf("answer %q: asked %q", tt.answer, out.String())
		}
	}
}

func TestRmRefuses(t *testing.T) {
	cfg := t.TempDir()
	write(t, filepath.Join(cfg, "projects", "-p", idA+".jsonl"), `{"aiTitle":"Alpha"}`)
	for _, id := range []string{"", "../../etc/passwd", "aaaaaaaa-1111-4111-8111-aaaaaaaaaaa*", idC} {
		if err := rm(io.Discard, strings.NewReader(""), cfg, id, false, time.Now()); err == nil {
			t.Errorf("rm(%q) succeeded", id)
		}
	}
	if _, err := os.Stat(filepath.Join(cfg, "projects", "-p", idA+".jsonl")); err != nil {
		t.Errorf("a refused rm removed another session: %v", err)
	}
}
