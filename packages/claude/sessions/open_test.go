package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

// hold takes the lock flock(1) takes on path, as a launch holds it while its
// claude runs, until the test ends.
func hold(t *testing.T, path string) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.Close() })
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
}

// launchFile is a launch's file in profile config holding data, a lock held
// on it when held says so.
func launchFile(t *testing.T, config, name, data string, held bool) string {
	t.Helper()
	path := filepath.Join(config, openDir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	if held {
		hold(t, path)
	}
	return path
}

func TestMark(t *testing.T) {
	// The sandbox's claude runs its hook through sh, and so does a claude it
	// started in the Bash tool (`claude -p`).
	root := filepath.Join(t.TempDir(), "proc")
	for _, p := range []proc{
		{pid: 1, comm: "bwrap"},
		{pid: 2, ppid: 1, comm: ".claude-wrapped"},
		{pid: 3, ppid: 2, comm: "sh"},
		{pid: 4, ppid: 2, comm: "bash"},
		{pid: 5, ppid: 4, comm: "claude"},
		{pid: 6, ppid: 5, comm: "sh"},
	} {
		addProc(t, root, p)
	}
	tests := []struct {
		name, input, before, proc string
		pid                       int
		want                      string // the file's content after
		wantErr                   bool
	}{
		{name: "the session claude starts", input: `{"session_id":"` + idA + `","source":"startup"}`, proc: root, pid: 3, want: idA},
		{name: "the session claude clears into", input: `{"session_id":"` + idB + `","source":"clear"}`, before: idA, proc: root, pid: 3, want: idB},
		{name: "a claude a claude started", input: `{"session_id":"` + idB + `"}`, before: idA, proc: root, pid: 6, want: idA},
		{name: "no /proc to tell", input: `{"session_id":"` + idB + `"}`, before: idA, pid: 6, want: idB},
		{name: "no session in the input", input: `{"source":"startup"}`, before: idA, proc: root, pid: 3, want: idA, wantErr: true},
		{name: "not a session id", input: `{"session_id":"../x"}`, proc: root, pid: 3, wantErr: true},
		{name: "not JSON", input: "session", proc: root, pid: 3, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := launchFile(t, t.TempDir(), "x", tt.before, true)
			if err := mark(strings.NewReader(tt.input), path, tt.proc, tt.pid); (err != nil) != tt.wantErr {
				t.Fatalf("mark = %v, want an error: %v", err, tt.wantErr)
			}
			if got := string(must(os.ReadFile(path))); got != tt.want {
				t.Errorf("the file holds %q, want %q", got, tt.want)
			}
			// Written in place: the lock is still held on the file at path.
			if _, held, err := lockedID(path); err != nil || !held {
				t.Errorf("lockedID = held %v, %v: the file at path is not the one the launch holds", held, err)
			}
		})
	}
	if err := mark(strings.NewReader("not read"), "", root, 3); err != nil {
		t.Errorf("mark for a claude started without a file = %v, want nothing done", err)
	}
}

func TestOpenByLock(t *testing.T) {
	home := t.TempDir()
	now := time.Now()
	one, two := filepath.Join(home, ".claude-1"), filepath.Join(home, ".claude-2")
	launchFile(t, one, "open", idA, true)
	launchFile(t, two, "open", idB, true)
	launchFile(t, one, "starting", "", true) // its hook has yet to run
	launchFile(t, one, "garbled", "not an id", true)
	launchFile(t, filepath.Join(home, ".claude"), "x", idD, true) // not a profile __claude starts
	young := launchFile(t, one, "young", "", false)               // made, not yet locked
	ended := launchFile(t, one, "ended", idC, false)
	if err := os.Chtimes(ended, now.Add(-2*staleAfter), now.Add(-2*staleAfter)); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(one, openDir, "fifo"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, want := openByLock(home, now), map[string]bool{idA: true, idB: true}; !reflect.DeepEqual(got, want) {
		t.Errorf("openByLock = %v, want %v", got, want)
	}
	if _, err := os.Stat(ended); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a file whose launch ended is still there: %v", err)
	}
	if _, err := os.Stat(young); err != nil {
		t.Errorf("a file a launch just made is gone: %v", err)
	}
}

func TestOpenSessionsReadTheLaunchFile(t *testing.T) {
	tests := []struct {
		name, data string
		held       bool
		waits      int
	}{
		{name: "named", data: idA, held: true, waits: 0},
		{name: "not named yet", data: "", held: true, waits: 1},
		{name: "not held", data: idA, held: false, waits: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := newMachine(t)
			m.leave(t, 10, 11, 12, 13) // claude 12, which names session A at the first wait
			path := launchFile(t, filepath.Join(m.home, ".claude-1"), "x", tt.data, tt.held)
			addProc(t, m.h.proc, proc{
				pid: 12, ppid: 11, comm: ".claude-wrapped", tty: 34816, cwd: m.a, kids: []int{13},
				args: argsOf(t, m.h.proc, 12), env: append(envOf(t, m.h.proc, 12), openVar+"="+path),
			})
			sessions, notes, err := m.h.openSessions()
			if err != nil {
				t.Fatal(err)
			}
			if want := m.want()[:1]; !reflect.DeepEqual(sessions, want) || len(notes) != 0 {
				t.Errorf("sessions =\n%+v\nnotes %q\nwant\n%+v", sessions, notes, want)
			}
			if m.waits != tt.waits {
				t.Errorf("waited %d times, want %d", m.waits, tt.waits)
			}
		})
	}
}

func TestSavedLeavesOutWhatALockNames(t *testing.T) {
	home := t.TempDir()
	one := filepath.Join(home, ".claude-1")
	conversation(t, one, home, idA, "hello")
	conversation(t, one, home, idB, "bye")
	launchFile(t, one, "x", idA, true)
	dir := filepath.Join(home, "backups")
	now := time.Now()
	write(t, filepath.Join(dir, backupName(now)), string(must(json.Marshal(backupFile{
		Version: 1, Time: now,
		Sessions: []savedSession{{ID: idA, Config: one, Cwd: home, Title: "hello"}, {ID: idB, Config: one, Cwd: home, Title: "bye"}},
	}))))
	// No claude in /proc: the lock alone says session A is open.
	h := host{proc: filepath.Join(home, "proc"), uid: uint32(os.Getuid()), home: home, looks: 4, wait: func() {}}
	addProc(t, h.proc, proc{pid: 90, ppid: 1, comm: "zsh", tty: 34816, cwd: home})
	var out, notes bytes.Buffer
	if err := saved(&out, &notes, h, dir, now); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.String(), idB+"\t") || strings.Contains(out.String(), idA) {
		t.Errorf("out = %q, want session B only", out.String())
	}
	if !strings.Contains(notes.String(), `left out "hello" (~): it is open`) {
		t.Errorf("notes = %q, want session A left out as open", notes.String())
	}
}
