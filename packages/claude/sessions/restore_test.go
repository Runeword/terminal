package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestMain lets the test binary stand in for claude-sessions, for the steps
// TestRestoreWalk runs as fzf runs them.
func TestMain(m *testing.M) {
	if filepath.Base(os.Args[0]) == "claude-sessions" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// noClaude is a host whose /proc runs no claude.
func noClaude(t *testing.T, home string) host {
	t.Helper()
	h := host{proc: filepath.Join(home, "proc"), uid: uint32(os.Getuid()), home: home, looks: 4, wait: func() {}}
	addProc(t, h.proc, proc{pid: 90, ppid: 1, comm: "zsh", tty: 34816, cwd: home})
	return h
}

// restoreAll runs the picker over the backups in dir to an end that accepts
// those names (the newest alone when none): start, then picked. It returns
// picked's rows and the notes of both.
func restoreAll(t *testing.T, h host, dir string, now time.Time, names ...string) (rows, notes string) {
	t.Helper()
	r := restorer{dir: t.TempDir(), getenv: func(string) string { return "" }}
	var out, said bytes.Buffer
	if err := r.start(&said, h, dir, now); err != nil {
		t.Fatal(err)
	}
	st, err := r.loadState()
	if err != nil {
		t.Fatal(err)
	}
	if len(names) == 0 {
		names = []string{st.Backups[0].Name}
	}
	st.Accepted = names
	if err := r.saveState(st); err != nil {
		t.Fatal(err)
	}
	if err := r.picked(&out, &said, h.home, dir, now); err != nil {
		t.Fatal(err)
	}
	return out.String(), said.String()
}

// TestRestoreStart lists two backups of four files: one it can't read and one
// no backup are left out. Of the newest, one session can be resumed; the
// others are open, gone (their directory, their conversation), or can't be
// started from what the backup says (a title holding an escape), and one it
// holds twice counts once.
func TestRestoreStart(t *testing.T) {
	home := t.TempDir()
	one, two := filepath.Join(home, ".claude-1"), filepath.Join(home, ".claude-2")
	a, b, gone := filepath.Join(home, "work", "a"), filepath.Join(home, "work", "b"), filepath.Join(home, "work", "gone")
	for _, d := range []string{a, b} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Date(2026, 10, 16, 22, 30, 0, 0, time.UTC)
	path := conversation(t, one, a, idA, "unused")
	if err := os.Chtimes(path, now.Add(-3*time.Hour), now.Add(-3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	conversation(t, one, a, idC, "unused")
	conversation(t, one, gone, idD, "unused")
	launchFile(t, one, "x", idC, true)
	dir := filepath.Join(home, "backups")
	newest := backupAt(t, dir, now.Add(-5*time.Minute),
		savedSession{ID: idA, Config: one, Cwd: a, Title: "fix the build", Connections: []string{"gh"}},
		savedSession{ID: idB, Config: two, Cwd: b, Title: "its conversation\x1b[2J is gone"},
		savedSession{ID: idC, Config: one, Cwd: a, Title: "open now"},
		savedSession{ID: idD, Config: one, Cwd: gone, Title: "no directory"},
		savedSession{ID: idE, Config: one, Cwd: b, Title: "no conversation"},
		savedSession{ID: idA, Config: one, Cwd: b, Title: "saved twice"})
	unreadable := backupName(now.Add(-time.Hour))
	write(t, filepath.Join(dir, unreadable), "{")
	oldest := backupAt(t, dir, now.Add(-50*time.Hour), savedSession{ID: idA, Config: one, Cwd: "/srv/x\ty"})
	write(t, filepath.Join(dir, "notes.txt"), "x")

	r := restorer{dir: t.TempDir()}
	var notes bytes.Buffer
	if err := r.start(&notes, noClaude(t, home), dir, now); err != nil {
		t.Fatal(err)
	}
	when := func(d time.Duration) string { return now.Add(-d).Local().Format("Mon _2 Jan 15:04") }
	wantList := "5m    " + when(5*time.Minute) + "  6 sessions  ~/work/a, ~/work/b, ~/work/gone\n" +
		"2d    " + when(50*time.Hour) + "  1 session   /srv/x y\n"
	if list := string(must(os.ReadFile(r.path("backups")))); list != wantList {
		t.Errorf("backups =\n%q\nwant\n%q", list, wantList)
	}
	if want := "claude-sessions: left out a backup: ~/backups/" + unreadable + ": unexpected end of JSON input\n"; notes.String() != want {
		t.Errorf("notes = %q, want %q", notes.String(), want)
	}
	st := must(r.loadState())
	if !slices.Contains(st.Open, idC) {
		t.Errorf("open = %q, want session C in it", st.Open)
	}
	var names []string
	for _, b := range st.Backups {
		names = append(names, b.Name)
	}
	if want := []string{newest, oldest}; !reflect.DeepEqual(names, want) {
		t.Fatalf("backups = %q, want %q", names, want)
	}
	n, o := st.Backups[0], st.Backups[1]
	if len(n.Sessions) != 1 || n.Sessions[0].ID != idA || n.Sessions[0].Title != "fix the build" {
		t.Errorf("newest's sessions = %+v, want session A as it first holds it", n.Sessions)
	}
	if want := []string{"3h    ~/work/a  gh  fix the build"}; !reflect.DeepEqual(n.Rows, want) {
		t.Errorf("newest's rows =\n%q\nwant\n%q", n.Rows, want)
	}
	wantShown := "3h    ~/work/a     gh         fix the build\n" +
		dim + "?     ~/work/b     profile 2  its conversation [2J is gone" + reset + "\n" +
		dim + "open  ~/work/a" + strings.Repeat(" ", 16) + "open now" + reset + "\n" +
		dim + "gone  ~/work/gone" + strings.Repeat(" ", 13) + "no directory" + reset + "\n" +
		dim + "gone  ~/work/b" + strings.Repeat(" ", 16) + "no conversation" + reset + "\n"
	if n.Shown != wantShown {
		t.Errorf("newest shown =\n%q\nwant\n%q", n.Shown, wantShown)
	}
	if len(o.Sessions)+len(o.Rows) != 0 || o.Shown != dim+"?     /srv/x y"+reset+"\n" {
		t.Errorf("oldest = %+v, want nothing to resume, shown as clean text", o)
	}
}

func TestNoBackupYet(t *testing.T) {
	home := t.TempDir()
	h := noClaude(t, home)
	unreadable := filepath.Join(home, "unreadable")
	write(t, filepath.Join(unreadable, backupName(time.Now())), "{")
	for dir, want := range map[string]string{
		filepath.Join(home, "none"): "no backup yet",
		h.proc:                      "no backup yet",
		unreadable:                  "no backup can be read",
	} {
		var notes bytes.Buffer
		if err := (restorer{dir: t.TempDir()}).start(&notes, h, dir, time.Now()); err == nil || err.Error() != want {
			t.Errorf("start(%s) = %v, want %s", dir, err, want)
		}
	}
}

func TestRestoreWithoutProc(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "hello")
	dir := filepath.Join(home, "backups")
	now := time.Now()
	backupAt(t, dir, now, savedSession{ID: idA, Config: one, Cwd: home, Title: "hello"})
	rows, notes := restoreAll(t, host{proc: filepath.Join(home, "none"), home: home}, dir, now)
	if !strings.HasPrefix(rows, idA+"\t1\t"+home+"\t") || !strings.Contains(notes, "a session still open would be started twice") {
		t.Errorf("rows = %q, notes = %q", rows, notes)
	}
}

// TestPicked ends the picker with a whole backup: picked resumes every session
// of it that can be, as __claude started it, and says why it leaves out each
// of the others but the one it holds twice.
func TestPicked(t *testing.T) {
	m := newMachine(t)
	m.leave(t, 10, 11, 12, 13) // only claude 12 runs: session A is open
	one := filepath.Join(m.home, ".claude-1")
	conversation(t, one, m.b, idB, "unused")
	conversation(t, one, m.c, idD, "unused")
	gone := filepath.Join(m.home, "work", "gone")
	conversation(t, one, gone, idE, "unused")
	now := time.Date(2026, 10, 16, 22, 30, 0, 0, time.UTC)
	dir := filepath.Join(m.home, "backups")
	backupAt(t, dir, now.Add(-time.Hour),
		savedSession{ID: idA, Config: one, Cwd: m.a, Title: "open now"},
		savedSession{
			ID: idB, Config: one, Cwd: m.b, Title: "fine", Connections: []string{"gh", "jira"},
			NetAllow: "a.example b.example", Plugins: []string{"nix-lsp", "figma-mcp"}, TmuxSession: "work", TmuxWindow: 2,
		},
		savedSession{ID: idD, Config: one, Cwd: m.c, Title: "plain"},
		savedSession{ID: idC, Config: one, Cwd: m.b, Title: "no conversation in this profile"},
		savedSession{ID: idE, Config: one, Cwd: gone, Title: "no directory"},
		savedSession{ID: idG, Config: filepath.Join(m.home, ".claude"), Cwd: m.c, Title: "not an instance"},
		savedSession{ID: "not-an-id", Config: one, Cwd: m.c, Title: "bad id"},
		savedSession{ID: idH, Config: one, Cwd: m.c, Title: "tab\tin title"},
		savedSession{ID: idB, Config: one, Cwd: m.c, Title: "fine, saved twice"})
	backupAt(t, dir, now.Add(-2*time.Hour))
	rows, notes := restoreAll(t, m.h, dir, now)
	wantRows := idB + "\t1\t" + m.b + "\tgh,jira\ta.example b.example\tnix-lsp,figma-mcp\twork\tfine\n" +
		idD + "\t1\t" + m.c + "\t-\t-\t-\t-\tplain\n"
	if rows != wantRows {
		t.Errorf("rows =\n%q\nwant\n%q", rows, wantRows)
	}
	wantNotes := "claude-sessions: left out \"open now\" (~/work/a): it is open\n" +
		"claude-sessions: left out \"no conversation in this profile\" (~/work/b): its conversation is gone from profile 1\n" +
		"claude-sessions: left out \"no directory\" (~/work/gone): its directory is gone\n" +
		"claude-sessions: left out \"not an instance\" (~/work/c): the backup can't say how to start it\n" +
		"claude-sessions: left out \"bad id\" (~/work/c): the backup can't say how to start it\n" +
		"claude-sessions: left out \"tab\\tin title\" (~/work/c): the backup can't say how to start it\n"
	if notes != wantNotes {
		t.Errorf("notes =\n%s\nwant\n%s", notes, wantNotes)
	}
}

// TestPickedFromSeveralBackups accepts two backups of three: the sessions of
// the newer come first, a session both hold comes once, as the newer saved
// it, and the backup left out adds none.
func TestPickedFromSeveralBackups(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	for _, id := range []string{idA, idB, idC, idD} {
		conversation(t, one, home, id, "unused")
	}
	now := time.Date(2026, 10, 16, 22, 30, 0, 0, time.UTC)
	dir := filepath.Join(home, "backups")
	newer := backupAt(t, dir, now.Add(-time.Hour),
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b, as saved last", TmuxSession: "2"},
		savedSession{ID: idA, Config: one, Cwd: home, Title: "a"})
	backupAt(t, dir, now.Add(-2*time.Hour), savedSession{ID: idD, Config: one, Cwd: home, Title: "d"})
	older := backupAt(t, dir, now.Add(-3*time.Hour),
		savedSession{ID: idC, Config: one, Cwd: home, Title: "c"},
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b, as saved before", TmuxSession: "1"})
	rows, notes := restoreAll(t, noClaude(t, home), dir, now, older, newer)
	var got []string
	for _, line := range lines(rows) {
		if f := strings.Split(line, "\t"); len(f) == 8 {
			got = append(got, f[0]+" "+f[6]+" "+f[7])
		}
	}
	if want := []string{idB + " 2 b, as saved last", idA + " - a", idC + " - c"}; !reflect.DeepEqual(got, want) {
		t.Errorf("rows =\n%q\nwant\n%q", got, want)
	}
	if notes != "" {
		t.Errorf("notes = %q, want none", notes)
	}
}

// TestPickedTakesTheDrillsPicks ends the picker with backups a drill picked
// some sessions of: picked takes those of such a backup, and says why it
// leaves out a session of a whole backup only.
func TestPickedTakesTheDrillsPicks(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	for _, id := range []string{idA, idB, idC, idD} {
		conversation(t, one, home, id, "unused")
	}
	launchFile(t, one, "x", idD, true)
	now := time.Date(2026, 10, 16, 22, 30, 0, 0, time.UTC)
	dir := filepath.Join(home, "backups")
	newer := backupAt(t, dir, now.Add(-time.Hour),
		savedSession{ID: idA, Config: one, Cwd: home, Title: "a"},
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b", TmuxSession: "2"})
	older := backupAt(t, dir, now.Add(-2*time.Hour),
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b", TmuxSession: "1"},
		savedSession{ID: idC, Config: one, Cwd: home, Title: "c"},
		savedSession{ID: idD, Config: one, Cwd: home, Title: "d, open"})
	tests := []struct {
		name     string
		accepted []string
		picks    map[string][]string
		want     []string // each row's id and tmux session
		notes    string
	}{
		{
			name: "a whole backup and some of another", accepted: []string{newer, older},
			picks: map[string][]string{older: {idC}},
			want:  []string{idA + " -", idB + " 2", idC + " -"},
		},
		{
			name: "some of one backup", accepted: []string{older},
			picks: map[string][]string{older: {idC, idB}},
			want:  []string{idB + " 1", idC + " -"},
		},
		{
			name: "a whole backup says why it leaves one out", accepted: []string{older},
			want:  []string{idB + " 1", idC + " -"},
			notes: "claude-sessions: left out \"d, open\" (~): it is open\n",
		},
		{name: "cancelled"},
	}
	h := noClaude(t, home)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := restorer{dir: t.TempDir()}
			var out, notes bytes.Buffer
			if err := r.start(&notes, h, dir, now); err != nil {
				t.Fatal(err)
			}
			st := must(r.loadState())
			st.Accepted, st.Picks = tt.accepted, tt.picks
			if err := r.saveState(st); err != nil {
				t.Fatal(err)
			}
			if err := r.picked(&out, &notes, home, dir, now); err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, line := range lines(out.String()) {
				f := strings.Split(line, "\t")
				got = append(got, f[0]+" "+f[6])
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("rows = %q, want %q", got, tt.want)
			}
			if notes.String() != tt.notes {
				t.Errorf("notes = %q, want %q", notes.String(), tt.notes)
			}
		})
	}
}

// restoreBackups is the backups key and load are run against: the newest
// holds sessions A, B and C, the next D, and the oldest none that can be
// resumed.
func restoreBackups() []restoreBackup {
	session := func(id string) savedSession { return savedSession{ID: id} }
	return []restoreBackup{
		{Name: "n.json", Sessions: []savedSession{session(idA), session(idB), session(idC)}, Rows: []string{"a", "b", "c"}},
		{Name: "m.json", Sessions: []savedSession{session(idD)}, Rows: []string{"d"}},
		{Name: "o.json"},
	}
}

// TestRestoreKeyAndLoad presses one key, then runs load as fzf would once the
// reload lands.
func TestRestoreKeyAndLoad(t *testing.T) {
	tests := []struct {
		name     string
		state    restoreState      // state.json before the key, but its backups
		query    string            // the backups query saved at the drill
		env      map[string]string // FZF_SELECT_COUNT, FZF_QUERY, FZF_INPUT_STATE
		key      string
		focus    string // {n}
		sel      []int  // {+n}
		want     string // key's actions; <dir> is the state directory
		load     string // load's actions
		sessions string // the sessions file a drill wrote
		saved    string // the query file a drill wrote
		drill    string // the drilled backup afterwards
		picks    map[string][]string
		accepted []string
	}{
		{name: "left edits the query", key: "left", focus: "0", want: "backward-char"},
		{name: "esc aborts from search mode", key: "esc", focus: "0", want: "abort"},
		{name: "esc leaves nav mode", key: "esc", focus: "0", env: map[string]string{"FZF_INPUT_STATE": "disabled"}, want: "trigger(alt-i)"},
		{name: "enter with no backup listed", key: "enter", focus: ""},
		{name: "right on a backup with none to resume", key: "right", focus: "2"},
		{
			name: "enter on a backup with none to resume accepts", key: "enter", focus: "2",
			env: map[string]string{"FZF_SELECT_COUNT": "1"}, sel: []int{1},
			want: "accept", accepted: []string{"m.json"},
		},
		{
			name: "drill", key: "enter", focus: "0", sel: []int{0},
			want: "reload-sync(cat '<dir>/sessions')", load: "first", sessions: "a\nb\nc\n", drill: "n.json",
		},
		{
			name: "drill clears the query and marks every session of a marked backup", key: "right", focus: "0",
			env: map[string]string{"FZF_SELECT_COUNT": "1", "FZF_QUERY": "x"}, sel: []int{0},
			want: "reload-sync(cat '<dir>/sessions')", load: "change-query()+wait+select-all+first",
			sessions: "a\nb\nc\n", saved: "x", drill: "n.json",
		},
		{
			name: "drill marks the picks", key: "enter", focus: "0",
			state: restoreState{Picks: map[string][]string{"n.json": {idC, idA}}},
			env:   map[string]string{"FZF_SELECT_COUNT": "1"}, sel: []int{0},
			want: "reload-sync(cat '<dir>/sessions')", load: "pos(1)+select+pos(3)+select+first",
			sessions: "a\nb\nc\n", drill: "n.json", picks: map[string][]string{"n.json": {idC, idA}},
		},
		{name: "right in the sessions list edits the query", state: restoreState{Drill: "n.json"}, key: "right", focus: "0", want: "forward-char", drill: "n.json"},
		{
			name: "back records some, restores marks and cursor", state: restoreState{Drill: "n.json", Marks: []string{"m.json"}},
			key: "left", focus: "2", env: map[string]string{"FZF_SELECT_COUNT": "2"}, sel: []int{0, 2},
			want: "reload-sync(cat '<dir>/backups')", load: "pos(1)+select+pos(2)+select+pos(1)",
			picks: map[string][]string{"n.json": {idA, idC}},
		},
		{
			name: "back with every session marked keeps the backup whole", state: restoreState{Drill: "n.json", Picks: map[string][]string{"n.json": {idA}}},
			key: "esc", focus: "0", env: map[string]string{"FZF_SELECT_COUNT": "3"}, sel: []int{0, 1, 2},
			want: "reload-sync(cat '<dir>/backups')", load: "pos(1)+select+pos(1)",
		},
		{
			name: "back with nothing marked drops the backup and restores the query",
			state: restoreState{
				Drill: "n.json", Marks: []string{"n.json", "m.json"},
				Picks: map[string][]string{"n.json": {idA}},
			},
			query: "fo", env: map[string]string{"FZF_QUERY": "x"},
			key: "esc", focus: "1", sel: []int{1},
			want: "reload-sync(cat '<dir>/backups')",
			load: "change-query()+wait+pos(2)+select+pos(1)+" +
				"track-current+transform-query(cat '<dir>/query')+wait+untrack-current",
		},
		{
			name: "enter in the sessions list accepts as shown",
			state: restoreState{
				Drill: "n.json", Marks: []string{"m.json"},
				Picks: map[string][]string{"n.json": {idA}},
			},
			key: "enter", focus: "1", env: map[string]string{"FZF_SELECT_COUNT": "2"}, sel: []int{1, 2},
			want: "accept", drill: "n.json",
			picks: map[string][]string{"n.json": {idB, idC}}, accepted: []string{"m.json", "n.json"},
		},
		{
			name:  "enter with no session marked accepts the other backups marked",
			state: restoreState{Drill: "n.json", Marks: []string{"n.json", "m.json"}},
			key:   "enter", focus: "1", sel: []int{1},
			want: "accept", drill: "n.json", accepted: []string{"m.json"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := restorer{dir: t.TempDir(), getenv: func(k string) string { return tt.env[k] }}
			if err := os.WriteFile(r.path("query"), []byte(tt.query), 0o600); err != nil {
				t.Fatal(err)
			}
			st := tt.state
			st.Backups = restoreBackups()
			if err := r.saveState(st); err != nil {
				t.Fatal(err)
			}

			got, err := r.key(tt.key, tt.focus, tt.sel)
			if err != nil {
				t.Fatalf("key: %v", err)
			}
			loaded, err := r.load()
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			in := func(s string) string { return strings.ReplaceAll(s, "<dir>", r.dir) }
			if got != in(tt.want) {
				t.Errorf("key = %q, want %q", got, in(tt.want))
			}
			if loaded != in(tt.load) {
				t.Errorf("load = %q, want %q", loaded, in(tt.load))
			}
			if tt.sessions != "" {
				if s, _ := os.ReadFile(r.path("sessions")); string(s) != tt.sessions {
					t.Errorf("sessions = %q, want %q", s, tt.sessions)
				}
			}
			if tt.saved != "" {
				if q, _ := os.ReadFile(r.path("query")); string(q) != tt.saved {
					t.Errorf("saved query = %q, want %q", q, tt.saved)
				}
			}
			st = must(r.loadState())
			if st.Drill != tt.drill {
				t.Errorf("drill = %q, want %q", st.Drill, tt.drill)
			}
			if len(st.Picks)+len(tt.picks) > 0 && !reflect.DeepEqual(st.Picks, tt.picks) {
				t.Errorf("picks = %q, want %q", st.Picks, tt.picks)
			}
			if !slices.Equal(st.Accepted, tt.accepted) {
				t.Errorf("accepted = %q, want %q", st.Accepted, tt.accepted)
			}
		})
	}
}

// TestRestoreShow previews a backup, led by the sessions a drill picked when
// it picked some of them only, then, drilled into it, a session of it.
func TestRestoreShow(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idB, "rename the module")
	backups := restoreBackups()
	backups[0].Sessions[1] = savedSession{ID: idB, Config: one, Cwd: home}
	backups[0].Shown, backups[1].Shown = "N\n", "M\n"
	r := restorer{dir: t.TempDir()}
	st := restoreState{Backups: backups, Picks: map[string][]string{"n.json": {idC, idB}}}
	if err := r.saveState(st); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct{ n, want string }{
		{"0", "◐ sessions: 2 3\nN\n"},
		{"1", "M\n"},
		{"3", ""},
		{"", ""},
	} {
		var w bytes.Buffer
		if err := r.show(&w, tt.n, 80, time.Now()); err != nil || w.String() != tt.want {
			t.Errorf("show %q = %q, %v; want %q", tt.n, w.String(), err, tt.want)
		}
	}
	st.Drill = "n.json"
	if err := r.saveState(st); err != nil {
		t.Fatal(err)
	}
	var w bytes.Buffer
	if err := r.show(&w, "1", 80, time.Now()); err != nil || !strings.Contains(w.String(), "rename the module") {
		t.Errorf("show 1, drilled = %q, %v; want session B's conversation", w.String(), err)
	}
	w.Reset()
	if err := r.show(&w, "3", 80, time.Now()); err != nil || w.Len() != 0 {
		t.Errorf("show 3, drilled = %q, %v; want nothing", w.String(), err)
	}
}

// TestRestoreDistrustsState plants in state.json what something else that can
// write it might: an fzf action queued for load, and sessions to resume that
// no backup holds, from backups that aren't. load passes no text of it on,
// and picked takes sessions from the backups alone.
func TestRestoreDistrustsState(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "hello")
	dir := filepath.Join(home, "backups")
	now := time.Now()
	real := backupAt(t, dir, now, savedSession{ID: idA, Config: one, Cwd: home, Title: "hello"})
	outside := backupAt(t, home, now, savedSession{ID: idB, Config: one, Cwd: home, Title: "outside"})
	planted := restoreState{
		Backups: []restoreBackup{{Name: real, Sessions: []savedSession{
			{ID: idA, Config: one, Cwd: "/", Title: "hello", Connections: []string{"gh"}, NetAllow: "evil.example"},
			{ID: idC, Config: one, Cwd: home, Title: "planted"},
		}}},
		Picks:    map[string][]string{real: {idA, idC}},
		Accepted: []string{real, "../" + outside},
	}
	r := restorer{dir: t.TempDir(), getenv: func(string) string { return "" }}
	if err := r.saveState(planted); err != nil {
		t.Fatal(err)
	}
	var out, notes bytes.Buffer
	if err := r.picked(&out, &notes, home, dir, now); err != nil {
		t.Fatal(err)
	}
	if want := idA + "\t1\t" + home + "\t-\t-\t-\t-\thello\n"; out.String() != want {
		t.Errorf("rows = %q, want %q", out.String(), want)
	}
	if want := "claude-sessions: left out backup \"../" + outside + "\": it is gone\n"; notes.String() != want {
		t.Errorf("notes = %q, want %q", notes.String(), want)
	}
	for _, state := range []string{
		`{"pending":{"actions":"execute-silent(touch pwned)"}}`,
		`{"pending":{"select":["1)+execute-silent(touch pwned)"]}}`,
	} {
		if err := os.WriteFile(r.path("state.json"), []byte(state), 0o600); err != nil {
			t.Fatal(err)
		}
		if got, _ := r.load(); strings.Contains(got, "pwned") {
			t.Errorf("load passed state.json's text on as an action: %q", got)
		}
	}
}

func TestIndices(t *testing.T) {
	if got, err := indices([]string{"", "3", "0"}); err != nil || !reflect.DeepEqual(got, []int{3, 0}) {
		t.Errorf("indices = %v, %v; want [3 0]", got, err)
	}
	if _, err := indices([]string{"1", "x"}); err == nil {
		t.Error("indices took x for an index")
	}
}

// TestRestoreWalk runs a restore's steps as commands, as fzf runs them, past
// start, which runs here against a /proc with no claude in it: a real one
// would be watched for its session. Enter drills into the newest backup, Tab
// marks its second session and Left goes back; Tab marks the older backup
// too, Right drills into it, every session of it marked, and Enter accepts.
// picked then resumes the session marked of the newest, then the older's but
// the one both hold.
func TestRestoreWalk(t *testing.T) {
	home, bin := t.TempDir(), t.TempDir()
	self := must(os.Executable())
	cmd := filepath.Join(bin, "claude-sessions")
	if err := os.Symlink(self, cmd); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", filepath.Join(home, "state"))
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "first")
	conversation(t, one, home, idB, "second")
	conversation(t, one, home, idC, "third")
	now := time.Now()
	dir := backupDir(home)
	backupAt(t, dir, now.Add(-time.Hour),
		savedSession{ID: idA, Config: one, Cwd: home, Title: "a"},
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b, as saved last"})
	backupAt(t, dir, now.Add(-2*time.Hour),
		savedSession{ID: idB, Config: one, Cwd: home, Title: "b, as saved before", TmuxSession: "old"},
		savedSession{ID: idC, Config: one, Cwd: home, Title: "c"})
	state := t.TempDir()
	var notes bytes.Buffer
	if err := (restorer{dir: state}).start(&notes, noClaude(t, home), dir, now); err != nil || notes.Len() != 0 {
		t.Fatalf("start: %v, notes %q", err, notes.String())
	}
	run := func(t *testing.T, env string, args ...string) string {
		t.Helper()
		c := exec.Command(cmd, append([]string{"restore", args[0], state}, args[1:]...)...)
		c.Env = append(os.Environ(), strings.Fields(env)...)
		out, err := c.Output()
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			t.Fatalf("restore %s: %v: %s", strings.Join(args, " "), err, exit.Stderr)
		}
		if err != nil {
			t.Fatal(err)
		}
		return string(out)
	}
	steps := []struct {
		env  string
		args []string
		want string
	}{
		{"", []string{"load"}, ""},
		{"FZF_SELECT_COUNT=0", []string{"key", "enter", "0", "0"}, "reload-sync(cat '" + state + "/sessions')"},
		{"", []string{"load"}, "first"},
		{"FZF_SELECT_COUNT=1", []string{"key", "left", "1", "1"}, "reload-sync(cat '" + state + "/backups')"},
		{"", []string{"load"}, "pos(1)+select+pos(1)"},
		{"FZF_SELECT_COUNT=2", []string{"key", "right", "1", "0", "1"}, "reload-sync(cat '" + state + "/sessions')"},
		{"", []string{"load"}, "select-all+first"},
		{"FZF_SELECT_COUNT=2", []string{"key", "enter", "0", "0", "1"}, "accept"},
		{"", []string{"picked"}, idB + "\t1\t" + home + "\t-\t-\t-\t-\tb, as saved last\n" + idC + "\t1\t" + home + "\t-\t-\t-\t-\tc\n"},
	}
	for _, s := range steps {
		if got := run(t, s.env, s.args...); got != s.want {
			t.Errorf("restore %s = %q, want %q", strings.Join(s.args, " "), got, s.want)
		}
		if s.args[0] == "load" && strings.HasPrefix(s.want, "pos(") {
			// Back in the backups list: the newest is previewed as picked in
			// part, as it was left, and each list as its rows.
			if got := run(t, "", "show", "0"); !strings.HasPrefix(got, "◐ sessions: 2\n") {
				t.Errorf("restore show 0 = %q, want it led by the session picked", got)
			}
		}
	}
	if got := string(must(os.ReadFile(filepath.Join(state, "backups")))); strings.Count(got, "\n") != 2 {
		t.Errorf("backups list = %q, want a row per backup", got)
	}
	if got := run(t, "", "show", "1"); !strings.Contains(got, "third") {
		t.Errorf("restore show 1, drilled into the older = %q, want session C's conversation", got)
	}
	// A step it doesn't know, or short of its arguments, is refused.
	for _, args := range [][]string{{"nope"}, {"key", "enter"}, {"show"}} {
		c := exec.Command(cmd, append([]string{"restore", args[0], state}, args[1:]...)...)
		if err := c.Run(); err == nil {
			t.Errorf("restore %s ran", strings.Join(args, " "))
		}
	}
}
