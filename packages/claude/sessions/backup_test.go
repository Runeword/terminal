package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

const (
	idD = "dddddddd-4444-4444-8444-dddddddddddd"
	idE = "eeeeeeee-5555-4555-8555-eeeeeeeeeeee"
	idF = "ffffffff-6666-4666-8666-ffffffffffff"
)

// proc is a process of a fake /proc tree: what backup reads of it.
type proc struct {
	pid, ppid int
	comm      string
	state     byte // 'S' when unset
	tty       int
	env       []string
	args      []string
	cwd       string
	kids      []int
}

// addProc writes p into the fake /proc at root.
func addProc(t *testing.T, root string, p proc) {
	t.Helper()
	dir := filepath.Join(root, strconv.Itoa(p.pid))
	if err := os.MkdirAll(filepath.Join(dir, "task", strconv.Itoa(p.pid)), 0o755); err != nil {
		t.Fatal(err)
	}
	if p.state == 0 {
		p.state = 'S'
	}
	kids := make([]string, len(p.kids))
	for i, k := range p.kids {
		kids[i] = strconv.Itoa(k) + " "
	}
	files := map[string]string{
		"stat":    fmt.Sprintf("%d (%s) %c %d %d %d %d -1 4194560 0 0\n", p.pid, p.comm, p.state, p.ppid, p.pid, p.pid, p.tty),
		"environ": strings.Join(p.env, "\x00") + "\x00",
		"cmdline": strings.Join(p.args, "\x00") + "\x00",
		filepath.Join("task", strconv.Itoa(p.pid), "children"): strings.Join(kids, ""),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if p.cwd != "" {
		_ = os.Remove(filepath.Join(dir, "cwd"))
		if err := os.Symlink(p.cwd, filepath.Join(dir, "cwd")); err != nil {
			t.Fatal(err)
		}
	}
}

// conversation writes session id's transcript to profile config, for the
// directory cwd, titled by a prompt.
func conversation(t *testing.T, config, cwd, id, prompt string) string {
	t.Helper()
	path := filepath.Join(config, "projects", dirName(cwd), id+".jsonl")
	write(t, path, `{"type":"user","entrypoint":"cli","message":{"content":"`+prompt+`"},"sessionId":"`+id+`"}`)
	return path
}

// machine is a fake host: two profiles, the directories sessions run in, and
// a /proc of claudes in every state backup tells apart. At the first wait,
// each claude still running starts a process; one starts it before it
// exec's, and only names its session at the second.
type machine struct {
	h         host
	home      string
	a, b, c   string // directories
	waits     int
	fullTable bool // whether claudes list no children, as without CONFIG_PROC_CHILDREN
}

func newMachine(t *testing.T) *machine {
	t.Helper()
	m := &machine{home: t.TempDir()}
	m.a, m.b, m.c = filepath.Join(m.home, "work", "a"), filepath.Join(m.home, "work", "b"), filepath.Join(m.home, "work", "c")
	for _, d := range []string{m.a, m.b, m.c} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	one, two := filepath.Join(m.home, ".claude-1"), filepath.Join(m.home, ".claude-2")
	conversation(t, one, m.a, idA, "fix the build")
	conversation(t, two, m.b, idC, "rename the module")
	root := filepath.Join(m.home, "proc")
	claude := func(pid, ppid int, cwd string, env ...string) proc {
		return proc{pid: pid, ppid: ppid, comm: ".claude-wrapped", tty: 34816, cwd: cwd, env: env, args: []string{"claude"}}
	}
	procs := []proc{
		// The sandbox launcher execs bwrap in the tmux pane, whose child,
		// PID 1 of the namespace, starts claude; claude's MCP server was
		// started for a session /clear has replaced since.
		{pid: 10, ppid: 1, comm: "bwrap", tty: 34816},
		{pid: 11, ppid: 10, comm: "bwrap", tty: 34816},
		func() proc {
			p := claude(12, 11, m.a, "CLAUDE_CONFIG_DIR="+one, "CLAUDE_SANDBOX_ALLOW_GH=1", "CLAUDE_SANDBOX_ALLOW_JIRA=0", "CLAUDE_SANDBOX_NET_ALLOW=api.example.com")
			p.args = []string{"claude", "--settings", "s.json", "--plugin-dir", "/p/nix-lsp", "--plugin-dir=/p/figma-mcp", "--resume", idB}
			p.kids = []int{13}
			return p
		}(),
		{pid: 13, ppid: 12, comm: "node", tty: 34816, env: []string{sessionVar + "=" + idB}},
		// A claude started by a claude: `claude -p` in the Bash tool.
		{pid: 30, ppid: 13, comm: "claude", tty: 34816, cwd: m.a, env: []string{"CLAUDE_CONFIG_DIR=" + one}},
		// The background agents' daemon has no terminal.
		{pid: 40, ppid: 1, comm: "claude", cwd: m.a, env: []string{"CLAUDE_CONFIG_DIR=" + one}},
		claude(20, 1, m.b, "CLAUDE_CONFIG_DIR="+two+"/"),
		func() proc { p := claude(50, 1, m.c, "CLAUDE_CONFIG_DIR="+one); p.state = 'T'; return p }(),
		claude(60, 1, m.c), // no CLAUDE_CONFIG_DIR: ~/.claude
		claude(70, 1, m.c, "CLAUDE_CONFIG_DIR="+one),
		claude(80, 1, m.c, "CLAUDE_CONFIG_DIR="+one),
		{pid: 90, ppid: 1, comm: "zsh", tty: 34816, cwd: m.c},
	}
	for _, p := range procs {
		addProc(t, root, p)
	}
	m.h = host{
		proc:  root,
		uid:   uint32(os.Getuid()),
		home:  m.home,
		looks: 4,
		panes: func() map[int]pane { return map[int]pane{10: {session: "work", window: 3}} },
	}
	m.h.wait = func() {
		m.waits++
		started := map[int]proc{
			12: {pid: 14, ppid: 12, comm: "claude-statusline", env: []string{sessionVar + "=" + idA}},
			20: {pid: 21, ppid: 20, comm: "claude-statusline", env: []string{"PATH=/bin"}}, // not exec'd yet
			60: {pid: 61, ppid: 60, comm: "claude-statusline", env: []string{sessionVar + "=" + idD}},
			70: {pid: 71, ppid: 70, comm: "zsh", env: []string{sessionVar + "=" + idE}},
		}
		switch m.waits {
		case 1:
			for parent, kid := range started {
				p, err := readStat(root, parent)
				if err != nil {
					continue // the test took it away
				}
				addProc(t, root, kid)
				kids := []int{kid.pid}
				if parent == 12 {
					kids = []int{13, 14}
				}
				addProc(t, root, proc{pid: parent, ppid: p.ppid, comm: p.comm, tty: p.tty, env: envOf(t, root, parent), args: argsOf(t, root, parent), kids: kids})
			}
		case 2:
			addProc(t, root, proc{pid: 21, ppid: 20, comm: "claude-statusline", env: []string{sessionVar + "=" + idC}})
		}
		if m.fullTable {
			m.dropChildren()
		}
	}
	return m
}

// dropChildren removes every process's list of children, as a kernel
// without CONFIG_PROC_CHILDREN has none.
func (m *machine) dropChildren() {
	for _, e := range must(os.ReadDir(m.h.proc)) {
		_ = os.Remove(filepath.Join(m.h.proc, e.Name(), "task", e.Name(), "children"))
	}
}

// leave takes every process but pids out of the machine's /proc.
func (m *machine) leave(t *testing.T, pids ...int) {
	t.Helper()
	for _, e := range must(os.ReadDir(m.h.proc)) {
		if pid, err := strconv.Atoi(e.Name()); err == nil && !slices.Contains(pids, pid) {
			if err := os.RemoveAll(filepath.Join(m.h.proc, e.Name())); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func envOf(t *testing.T, root string, pid int) []string {
	t.Helper()
	data := string(must(os.ReadFile(filepath.Join(root, strconv.Itoa(pid), "environ"))))
	return strings.Split(strings.TrimSuffix(data, "\x00"), "\x00")
}

func argsOf(t *testing.T, root string, pid int) []string {
	t.Helper()
	args, err := cmdline(root, pid)
	if err != nil {
		t.Fatal(err)
	}
	return args
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func (m *machine) want() []savedSession {
	return []savedSession{
		{
			ID: idA, Config: filepath.Join(m.home, ".claude-1"), Cwd: m.a, Title: "fix the build",
			Connections: []string{"gh"}, NetAllow: "api.example.com", Plugins: []string{"nix-lsp", "figma-mcp"},
			TmuxSession: "work", TmuxWindow: 3,
		},
		{ID: idC, Config: filepath.Join(m.home, ".claude-2"), Cwd: m.b, Title: "rename the module"},
	}
}

func (m *machine) wantNotes() []string {
	return []string{
		"claude 50 in ~/work/c: it is stopped; bring it back (fg), then back up again",
		"claude 60 in ~/work/c: its profile ~/.claude is not one __claude starts (~/.claude-<n>)",
		"claude 70 in ~/work/c: session " + idE + " has no conversation to resume yet",
		"claude 80 in ~/work/c: it started no process in 5s that names its session (its status line runs every refreshInterval)",
	}
}

func TestOpenSessions(t *testing.T) {
	for _, full := range []bool{false, true} {
		t.Run(fmt.Sprintf("full table %v", full), func(t *testing.T) {
			m := newMachine(t)
			if m.fullTable = full; full {
				m.dropChildren()
			}
			sessions, notes, err := m.h.openSessions()
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(sessions, m.want()) {
				t.Errorf("sessions =\n%+v\nwant\n%+v", sessions, m.want())
			}
			if !reflect.DeepEqual(notes, m.wantNotes()) {
				t.Errorf("notes =\n%q\nwant\n%q", notes, m.wantNotes())
			}
			if m.waits != m.h.looks-1 {
				t.Errorf("waited %d times, want %d: claude 80 is looked at to the end", m.waits, m.h.looks-1)
			}
		})
	}
}

func TestOpenSessionsAreThisUsers(t *testing.T) {
	m := newMachine(t)
	m.h.uid++
	sessions, notes, err := m.h.openSessions()
	if err != nil || len(sessions)+len(notes) != 0 || m.waits != 0 {
		t.Errorf("another user's machine: sessions %v, notes %q, %d waits, %v", sessions, notes, m.waits, err)
	}
}

func TestSessionIDsStopsWhenAllAreFound(t *testing.T) {
	m := newMachine(t)
	m.h.looks = 1000
	ids := m.h.sessionIDs([]int{12, 20})
	if want := map[int]string{12: idA, 20: idC}; !reflect.DeepEqual(ids, want) {
		t.Errorf("sessionIDs = %v, want %v", ids, want)
	}
	if m.waits != 2 {
		t.Errorf("waited %d times, want 2", m.waits)
	}
}

func TestNoProc(t *testing.T) {
	h := host{proc: filepath.Join(t.TempDir(), "none")}
	if _, _, err := h.openSessions(); err == nil || !strings.Contains(err.Error(), "finding the open sessions reads") {
		t.Errorf("openSessions without /proc: %v", err)
	}
}

func TestReadStat(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "7"), 0o755); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		stat string
		want procStat
		ok   bool
	}{
		{"7 (claude) S 1 7 7 34816 -1", procStat{comm: "claude", state: 'S', ppid: 1, tty: 34816}, true},
		{"7 (a) b (c) R 3 7 7 0 -1", procStat{comm: "a) b (c", state: 'R', ppid: 3}, true},
		{"7 (claude) S 1", procStat{}, false},
		{"7 claude S 1 7 7 0 -1", procStat{}, false},
	}
	for _, tt := range tests {
		if err := os.WriteFile(filepath.Join(root, "7", "stat"), []byte(tt.stat), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := readStat(root, 7)
		if (err == nil) != tt.ok || got != tt.want {
			t.Errorf("readStat(%q) = %+v, %v; want %+v, ok %v", tt.stat, got, err, tt.want, tt.ok)
		}
	}
}

func TestPluginsOf(t *testing.T) {
	args := []string{
		"claude", "--plugin-dir", "/p/nix-lsp", "--model", "x", "--plugin-dir=/q/figma-mcp/",
		"--plugin-dir", "/r/nix-lsp", "--plugin-dir", "/p/a,b", "--plugin-dir",
	}
	if got, want := pluginsOf(args), []string{"nix-lsp", "figma-mcp"}; !reflect.DeepEqual(got, want) {
		t.Errorf("pluginsOf = %q, want %q", got, want)
	}
}

func TestInstance(t *testing.T) {
	tests := []struct {
		config, want string
		ok           bool
	}{
		{"/h/.claude-1", "1", true},
		{"/h/.claude-12/", "12", true},
		{"/h/.claude", "", false},
		{"/h/.claude-", "", false},
		{"/h/.claude-x", "", false},
		{"/h/.claude-1/x", "", false},
		{"/g/.claude-1", "", false},
	}
	for _, tt := range tests {
		if got, ok := instance("/h", tt.config); got != tt.want || ok != tt.ok {
			t.Errorf("instance(%q) = %q, %v; want %q, %v", tt.config, got, ok, tt.want, tt.ok)
		}
	}
}

func TestTilde(t *testing.T) {
	for in, want := range map[string]string{"/h": "~", "/h/x": "~/x", "/hx": "/hx", "/g/h": "/g/h"} {
		if got := tilde("/h", in); got != want {
			t.Errorf("tilde(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBackup(t *testing.T) {
	m := newMachine(t)
	dir := filepath.Join(m.home, "state", "backups")
	now := time.Date(2026, 10, 16, 22, 30, 15, 0, time.UTC)
	// Twenty older backups, and files that aren't backups.
	for i := 0; i < maxBackups; i++ {
		write(t, filepath.Join(dir, backupName(now.Add(-time.Duration(i+1)*time.Hour))), "{}")
	}
	for _, name := range []string{".backup-1", "notes.txt", backupName(now.Add(-48*time.Hour)) + ".bak"} {
		write(t, filepath.Join(dir, name), "x")
	}
	var out, notes bytes.Buffer
	if err := backup(&out, &notes, m.h, dir, now); err != nil {
		t.Fatal(err)
	}
	wantOut := "backed up 2 sessions to ~/state/backups/20261016T223015Z.json\n" +
		"  ~/work/a  gh         fix the build\n" +
		"  ~/work/b  profile 2  rename the module\n"
	if out.String() != wantOut {
		t.Errorf("out =\n%s\nwant\n%s", out.String(), wantOut)
	}
	var wantNotes strings.Builder
	for _, n := range m.wantNotes() {
		wantNotes.WriteString("claude-sessions: skipped " + n + "\n")
	}
	if notes.String() != wantNotes.String() {
		t.Errorf("notes =\n%s\nwant\n%s", notes.String(), wantNotes.String())
	}
	var b backupFile
	if err := json.Unmarshal(must(os.ReadFile(filepath.Join(dir, backupName(now)))), &b); err != nil {
		t.Fatal(err)
	}
	if b.Version != 1 || !b.Time.Equal(now) || !reflect.DeepEqual(b.Sessions, m.want()) {
		t.Errorf("backup file = %+v", b)
	}
	names := must(backups(dir))
	if len(names) != maxBackups || names[len(names)-1] != backupName(now) || slices.Contains(names, backupName(now.Add(-maxBackups*time.Hour))) {
		t.Errorf("backups after pruning = %q", names)
	}
	for _, name := range []string{".backup-1", "notes.txt"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("pruning removed %s", name)
		}
	}
	if st := must(os.Stat(filepath.Join(dir, backupName(now)))); st.Mode().Perm() != 0o600 {
		t.Errorf("backup mode = %v", st.Mode().Perm())
	}
}

func TestBackupWithNothingOpenKeepsTheLastOne(t *testing.T) {
	home := t.TempDir()
	h := host{proc: filepath.Join(home, "proc"), uid: uint32(os.Getuid()), home: home, looks: 4, wait: func() {}, panes: func() map[int]pane { return nil }}
	addProc(t, h.proc, proc{pid: 90, ppid: 1, comm: "zsh", tty: 34816, cwd: home})
	dir := filepath.Join(home, "backups")
	var out, notes bytes.Buffer
	if err := backup(&out, &notes, h, dir, time.Now()); err != nil {
		t.Fatal(err)
	}
	if out.String() != "no session to back up: the last backup stays\n" || notes.Len() != 0 {
		t.Errorf("out = %q, notes = %q", out.String(), notes.String())
	}
	if _, err := os.Stat(dir); err == nil {
		t.Error("backup with nothing open made its directory")
	}
}

func TestSaved(t *testing.T) {
	m := newMachine(t)
	m.leave(t, 10, 11, 12, 13) // only claude 12 runs: session A is open
	one := filepath.Join(m.home, ".claude-1")
	conversation(t, one, m.b, idB, "unused")
	conversation(t, one, m.c, idD, "unused")
	gone := filepath.Join(m.home, "work", "gone")
	conversation(t, one, gone, idE, "unused")
	now := time.Date(2026, 10, 16, 22, 30, 0, 0, time.UTC)
	for _, id := range []string{idB, idD} {
		path := must(transcripts(one, id))[0]
		if err := os.Chtimes(path, now.Add(-5*time.Minute), now.Add(-5*time.Minute)); err != nil {
			t.Fatal(err)
		}
	}
	dir := filepath.Join(m.home, "backups")
	sessions := []savedSession{
		{ID: idA, Config: one, Cwd: m.a, Title: "open now"},
		{
			ID: idB, Config: one, Cwd: m.b, Title: "fine", Connections: []string{"gh", "jira"},
			NetAllow: "a.example b.example", Plugins: []string{"nix-lsp", "figma-mcp"}, TmuxSession: "work", TmuxWindow: 2,
		},
		{ID: idD, Config: one, Cwd: m.c, Title: "plain"},
		{ID: idC, Config: one, Cwd: m.b, Title: "no conversation in this profile"},
		{ID: idE, Config: one, Cwd: gone, Title: "no directory"},
		{ID: idE, Config: filepath.Join(m.home, ".claude"), Cwd: m.c, Title: "not an instance"},
		{ID: "not-an-id", Config: one, Cwd: m.c, Title: "bad id"},
		{ID: idD, Config: one, Cwd: m.c, Title: "tab\tin title"},
	}
	data := must(json.Marshal(backupFile{Version: 1, Time: now.Add(-time.Hour), Sessions: sessions}))
	write(t, filepath.Join(dir, backupName(now.Add(-time.Hour))), string(data))
	write(t, filepath.Join(dir, backupName(now.Add(-2*time.Hour))), `{"version":1,"sessions":[]}`)
	var out, notes bytes.Buffer
	if err := saved(&out, &notes, m.h, dir, now); err != nil {
		t.Fatal(err)
	}
	wantOut := idB + "\t1\t" + m.b + "\tgh,jira\ta.example b.example\tnix-lsp,figma-mcp\twork\tfine\t5m    ~/work/b  gh jira  fine\n" +
		idD + "\t1\t" + m.c + "\t-\t-\t-\t-\tplain\t5m    ~/work/c           plain\n"
	if out.String() != wantOut {
		t.Errorf("out =\n%q\nwant\n%q", out.String(), wantOut)
	}
	wantNotes := "claude-sessions: the backup of " + now.Add(-time.Hour).Local().Format("Mon 2 Jan 15:04") + ", 1h ago\n" +
		"claude-sessions: left out \"open now\" (~/work/a): it is open\n" +
		"claude-sessions: left out \"no conversation in this profile\" (~/work/b): its conversation is gone from profile 1\n" +
		"claude-sessions: left out \"no directory\" (~/work/gone): its directory is gone\n" +
		"claude-sessions: left out \"not an instance\" (~/work/c): the backup can't say how to start it\n" +
		"claude-sessions: left out \"bad id\" (~/work/c): the backup can't say how to start it\n" +
		"claude-sessions: left out \"tab\\tin title\" (~/work/c): the backup can't say how to start it\n"
	if notes.String() != wantNotes {
		t.Errorf("notes =\n%s\nwant\n%s", notes.String(), wantNotes)
	}
}

func TestSavedWithoutABackup(t *testing.T) {
	h := host{proc: t.TempDir(), home: t.TempDir()}
	for _, dir := range []string{filepath.Join(h.home, "none"), h.home} {
		var out, notes bytes.Buffer
		if err := saved(&out, &notes, h, dir, time.Now()); err == nil || err.Error() != "no backup yet" {
			t.Errorf("saved(%s) = %v, want no backup yet", dir, err)
		}
	}
}

func TestSavedWithoutProc(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "hello")
	dir := filepath.Join(home, "backups")
	now := time.Now()
	write(t, filepath.Join(dir, backupName(now)), string(must(json.Marshal(backupFile{
		Version: 1, Time: now,
		Sessions: []savedSession{{ID: idA, Config: one, Cwd: home, Title: "hello"}},
	}))))
	var out, notes bytes.Buffer
	if err := saved(&out, &notes, host{proc: filepath.Join(home, "none"), home: home}, dir, now); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), idA+"\t1\t"+home+"\t") || !strings.Contains(notes.String(), "a session still open would be started twice") {
		t.Errorf("out = %q, notes = %q", out.String(), notes.String())
	}
}

// registryMachine is a host as macOS has it: no /proc, so the sessions come
// from Claude Code's registry in each profile and ps's table, and the
// credentials from the tmux panes' start commands. Its claudes are in every
// state backup tells apart.
func registryMachine(t *testing.T) (host, *machine) {
	t.Helper()
	m := &machine{home: t.TempDir()}
	m.a, m.b, m.c = filepath.Join(m.home, "work", "a"), filepath.Join(m.home, "work", "b"), filepath.Join(m.home, "work", "c")
	for _, d := range []string{m.a, m.b, m.c} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	one, two, plain := filepath.Join(m.home, ".claude-1"), filepath.Join(m.home, ".claude-2"), filepath.Join(m.home, ".claude")
	conversation(t, one, m.a, idA, "fix the build")
	conversation(t, two, m.b, idC, "rename the module")
	conversation(t, plain, m.c, idD, "plain claude")
	entry := func(config string, pid int, fields string) {
		write(t, filepath.Join(config, "sessions", strconv.Itoa(pid)+".json"), fmt.Sprintf(`{"pid":%d,%s}`, pid, fields))
	}
	live := func(id, cwd, start string) string {
		return fmt.Sprintf(`"sessionId":%q,"cwd":%q,"kind":"interactive","procStart":%q,"status":"idle"`, id, cwd, start)
	}
	entry(one, 101, live(idA, m.a, "Wed Oct  7 08:23:45 2026")) // in tmux, with credentials
	entry(two, 202, live(idC, m.b, "Sat Oct 17 09:00:00 2026")) // outside tmux
	entry(plain, 303, live(idD, m.c, "Sat Oct 17 09:00:00 2026"))
	entry(one, 404, live(idB, m.a, "Sat Oct 17 07:00:00 2026")) // its PID runs another process now
	entry(one, 505, live(idB, m.a, "Sat Oct 17 09:00:00 2026")) // gone
	entry(one, 606, strings.Replace(live(idB, m.a, "Sat Oct 17 09:00:00 2026"), `"interactive"`, `"bg"`, 1))
	entry(one, 707, live(idB, m.a, "Sat Oct 17 09:00:00 2026")+`,"spare":true`)
	entry(filepath.Join(m.home, ".claude-1.bak"), 808, live(idB, m.a, "Sat Oct 17 09:00:00 2026"))
	entry(one, 909, fmt.Sprintf(`"sessionId":%q,"cwd":%q`, idE, m.c)) // no procStart: runs a claude
	entry(one, 910, fmt.Sprintf(`"sessionId":%q,"cwd":%q`, idB, m.c)) // no procStart: runs vim
	write(t, filepath.Join(one, "sessions", "911.json"), `{"pid":1,"sessionId":"`+idB+`"}`)
	entry(one, 912, live("", m.c, "Sat Oct 17 09:00:00 2026"))
	entry(one, 913, live(idF, "", "Sat Oct 17 09:00:00 2026"))
	write(t, filepath.Join(one, "sessions", "notes.txt"), "x")
	table := strings.Join([]string{
		"    1     0 Sat Oct 17 06:00:00 2026 /sbin/launchd",
		"  101     1 Wed Oct  7 08:23:45 2026 claude --settings s.json --plugin-dir /p/nix-lsp --plugin-dir=/p/figma-mcp --resume " + idB,
		"  200     1 Sat Oct 17 08:59:00 2026 -zsh",
		"  202   200 Sat Oct 17 09:00:00 2026 claude --settings s.json",
		"  300     1 Sat Oct 17 08:59:00 2026 -zsh",
		"  303   300 Sat Oct 17 09:00:00 2026 claude",
		"  404     1 Sat Oct 17 09:30:00 2026 claude",
		"  606     1 Sat Oct 17 09:00:00 2026 claude --bg",
		"  707     1 Sat Oct 17 09:00:00 2026 claude",
		"  808     1 Sat Oct 17 09:00:00 2026 claude",
		"  909   300 Sat Oct 17 09:00:00 2026 claude",
		"  910     1 Sat Oct 17 09:00:00 2026 vim notes",
		"  911     1 Sat Oct 17 09:00:00 2026 claude",
		"  912   300 Sat Oct 17 09:00:00 2026 claude",
		"  913   300 Sat Oct 17 09:00:00 2026 claude",
		"garbage",
	}, "\n") + "\n"
	h := host{
		home: m.home,
		ps:   func() ([]byte, error) { return []byte(table), nil },
		panes: func() map[int]pane {
			return map[int]pane{
				// The sandbox-free macOS launch: the pane's shell execs
				// claude-macos, which execs claude, all one process.
				101: {session: "work", window: 3, start: `"CLAUDE_SANDBOX_ALLOW_FIREBASE=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 FIGMA_API_KEY=$(pass show \"\${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}\" 2>/dev/null) CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-1 /p/claude-macos claude  --plugin-dir /p/nix-lsp --plugin-dir /p/figma-mcp --resume ` + idB + ` "`},
				300: {session: "other", window: 1},
			}
		},
	}
	return h, m
}

func TestRegistryOpenSessions(t *testing.T) {
	h, m := registryMachine(t)
	sessions, notes, err := h.openSessions()
	if err != nil {
		t.Fatal(err)
	}
	want := []savedSession{
		{
			ID: idA, Config: filepath.Join(m.home, ".claude-1"), Cwd: m.a, Title: "fix the build",
			Connections: []string{"jira", "firebase"}, Plugins: []string{"nix-lsp", "figma-mcp"},
			TmuxSession: "work", TmuxWindow: 3,
		},
		{ID: idC, Config: filepath.Join(m.home, ".claude-2"), Cwd: m.b, Title: "rename the module"},
	}
	if !reflect.DeepEqual(sessions, want) {
		t.Errorf("sessions =\n%+v\nwant\n%+v", sessions, want)
	}
	wantNotes := []string{
		"claude 303 in ~/work/c: its profile ~/.claude is not one __claude starts (~/.claude-<n>)",
		"claude 909 in ~/work/c: session " + idE + " has no conversation to resume yet",
		"claude 912 in ~/work/c: its registry entry names no session",
		"claude 913: its registry entry names no directory",
	}
	if !reflect.DeepEqual(notes, wantNotes) {
		t.Errorf("notes =\n%q\nwant\n%q", notes, wantNotes)
	}
}

func TestRegistryWithoutPS(t *testing.T) {
	h := host{home: t.TempDir(), ps: func() ([]byte, error) { return nil, errors.New("no ps") }}
	if _, _, err := h.openSessions(); err == nil || err.Error() != "finding the open sessions runs ps: no ps" {
		t.Errorf("openSessions without ps: %v", err)
	}
}

func TestSavedLeavesOutWhatTheRegistrySaysIsOpen(t *testing.T) {
	h, m := registryMachine(t)
	one := filepath.Join(m.home, ".claude-1")
	conversation(t, one, m.b, idB, "closed")
	dir := filepath.Join(m.home, "backups")
	now := time.Now()
	write(t, filepath.Join(dir, backupName(now)), string(must(json.Marshal(backupFile{
		Version: 1, Time: now,
		Sessions: []savedSession{{ID: idA, Config: one, Cwd: m.a, Title: "open"}, {ID: idB, Config: one, Cwd: m.b, Title: "closed"}},
	}))))
	var out, notes bytes.Buffer
	if err := saved(&out, &notes, h, dir, now); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), idB+"\t1\t"+m.b+"\t") || strings.Count(out.String(), "\n") != 1 ||
		!strings.Contains(notes.String(), `left out "open" (~/work/a): it is open`) {
		t.Errorf("out = %q, notes = %q", out.String(), notes.String())
	}
}

func TestConnectionsOf(t *testing.T) {
	tests := []struct {
		name, start string
		want        []string
	}{
		{"as tmux quotes it", `"CLAUDE_SANDBOX_ALLOW_FIREBASE=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_NET_ALLOW=a.example\\ b.example CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-1 claude "`, []string{"jira", "firebase"}},
		{"unquoted", `CLAUDE_SANDBOX_ALLOW_GH=1 claude`, []string{"gh"}},
		{"single-quoted", `'CLAUDE_SANDBOX_ALLOW_GH=1 claude'`, []string{"gh"}},
		{"turned off", `"CLAUDE_SANDBOX_ALLOW_GH=0 CLAUDE_CONFIG_DIR=\$HOME/.claude-1 claude"`, nil},
		{"past the command's start", `"CLAUDE_CODE_SYNTAX_HIGHLIGHT=false claude CLAUDE_SANDBOX_ALLOW_GH=1 --resume x"`, nil},
		{"one it doesn't know", `"CLAUDE_SANDBOX_ALLOW_GOOGLE_WORKSPACE=1 claude"`, nil},
		{"a pane started with the shell", ``, nil},
	}
	for _, tt := range tests {
		if got := connectionsOf(tt.start); !reflect.DeepEqual(got, tt.want) {
			t.Errorf("%s: connectionsOf = %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestParsePS(t *testing.T) {
	ps, started, commands := parsePS([]byte("  101     1 Wed Oct  7 08:23:45 2026 claude --plugin-dir /p/a b\n" +
		"1 0 Thu Jan  1 00:00:00 1970\n" +
		"x 1 Thu Jan  1 00:00:00 1970 nope\n" +
		"7 1 Thu Jan\n"))
	if want := map[int]procStat{101: {ppid: 1}, 1: {}}; !reflect.DeepEqual(ps, want) {
		t.Errorf("table = %v, want %v", ps, want)
	}
	if want := map[int]string{101: "Wed Oct 7 08:23:45 2026", 1: "Thu Jan 1 00:00:00 1970"}; !reflect.DeepEqual(started, want) {
		t.Errorf("started = %q, want %q", started, want)
	}
	if want := map[int]string{101: "claude --plugin-dir /p/a b", 1: ""}; !reflect.DeepEqual(commands, want) {
		t.Errorf("commands = %q, want %q", commands, want)
	}
}

// TestRegistryFindsARealProcess runs ps as backup does, against an entry whose
// procStart is what Claude Code records: `ps -o lstart=` for the process, in
// the C locale and UTC, trimmed. Without a ps (a build sandbox) it can't run.
func TestRegistryFindsARealProcess(t *testing.T) {
	if _, err := exec.LookPath("ps"); err != nil {
		t.Skip("no ps")
	}
	sleep := exec.Command("sleep", "30")
	if err := sleep.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = sleep.Process.Kill(); _ = sleep.Wait() }()
	pid := sleep.Process.Pid
	lstart := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	lstart.Env = append(os.Environ(), "LC_ALL=C", "TZ=UTC")
	start, err := lstart.Output()
	if err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "hello")
	h := host{home: home, ps: psTable, panes: func() map[int]pane { return nil }}
	for _, tt := range []struct {
		procStart string
		want      int
	}{
		{strings.TrimSpace(string(start)), 1},
		{"Thu Jan  1 00:00:00 1970", 0},
	} {
		write(t, filepath.Join(one, "sessions", strconv.Itoa(pid)+".json"),
			fmt.Sprintf(`{"pid":%d,"sessionId":%q,"cwd":%q,"kind":"interactive","procStart":%q}`, pid, idA, home, tt.procStart))
		_, found, err := h.claudes()
		if err != nil || len(found) != tt.want || tt.want == 1 && (found[0].pid != pid || found[0].id != idA) {
			t.Errorf("procStart %q: found %+v, %v", tt.procStart, found, err)
		}
	}
}
