package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Which session a claude has open, as its launch records it. __claude
// (claude.bash) starts claude under `flock -F <file>`, <file> being a file of
// the launch's own in the profile's open-sessions/, which it names to claude
// in $CLAUDE_SESSIONS_OPEN, and claude's SessionStart hook runs mark, which
// writes into it the id of each session claude starts, resumes or clears
// into. flock locks the file and execs into claude, which holds the lock for
// as long as it runs, and the kernel drops it once claude and what it started
// have ended, however they end (the sandbox ends them together): a held lock
// that names a session says for sure that session is open, where watching for
// a process that names it can miss it (APUE §13.5's single-instance lock, with
// the session where it writes the PID).
const (
	openVar = "CLAUDE_SESSIONS_OPEN"
	openDir = "open-sessions"
	// staleAfter is how old a file no lock is held on has to be before
	// openByLock removes it: a launch makes its file just before flock locks
	// it.
	staleAfter = time.Minute
)

// mark is claude's SessionStart hook: it writes the session the hook's input
// in names into file, $CLAUDE_SESSIONS_OPEN, and does nothing for a claude
// started without one. It writes in place: the lock is on that very file,
// which a rename would replace. A claude a claude starts (`claude -p`
// in the Bash tool) inherits the variable, so the claude above process pid,
// which ran the hook, is passed over when a claude is above it in turn, as
// backup passes it over; with no /proc (proc "") that can't be told, and it
// writes.
func mark(in io.Reader, file, proc string, pid int) error {
	if file == "" {
		return nil
	}
	var input struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(in).Decode(&input); err != nil {
		return fmt.Errorf("reading the hook's input: %w", err)
	}
	if !uuidRE.MatchString(input.SessionID) {
		return fmt.Errorf("the hook's input names no session: %q", input.SessionID)
	}
	if proc != "" && underClaude(proc, pid) {
		return nil
	}
	f, err := os.OpenFile(file, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	_, err = f.WriteAt([]byte(input.SessionID), 0)
	if err == nil {
		err = f.Truncate(int64(len(input.SessionID)))
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// underClaude reports whether the claude process pid runs under was started
// by a claude: one is above it in turn.
func underClaude(proc string, pid int) bool {
	ps, err := processes(proc)
	if err != nil {
		return false
	}
	for steps := 0; steps < len(ps); steps++ {
		st, ok := ps[pid]
		if !ok {
			return false
		}
		if isClaude(st) {
			return claudeAbove(ps, st.ppid)
		}
		pid = st.ppid
	}
	return false
}

// lockedID reads a launch's file: the session it names ("" until the hook
// has written one) and whether a lock is held on it. It opens the file
// without waiting and reads only a regular file: a session can write its
// profile, and a FIFO planted there would hang the restore.
func lockedID(path string) (id string, held bool, err error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", false, err
	}
	defer func() { _ = f.Close() }() // read only; closing drops a lock this took
	info, err := f.Stat()
	if err != nil {
		return "", false, err
	}
	if !info.Mode().IsRegular() {
		return "", false, fmt.Errorf("%s is not a regular file", path)
	}
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB)
	if err == nil {
		return "", false, nil
	}
	if !errors.Is(err, syscall.EWOULDBLOCK) {
		return "", false, err
	}
	data, err := io.ReadAll(io.LimitReader(f, 64))
	if err != nil {
		return "", true, err
	}
	if id = string(data); !uuidRE.MatchString(id) {
		id = ""
	}
	return id, true, nil
}

// openByLock is the sessions a held lock names, in the profiles under home
// that __claude starts. A file no lock is held on is what a launch left when
// it ended: it goes once it is staleAfter old.
func openByLock(home string, now time.Time) map[string]bool {
	open := map[string]bool{}
	entries, _ := os.ReadDir(home)
	for _, profile := range entries {
		config := filepath.Join(home, profile.Name())
		if _, ok := instance(home, config); !ok {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(config, openDir))
		for _, f := range files {
			path := filepath.Join(config, openDir, f.Name())
			id, held, err := lockedID(path)
			switch {
			case err != nil:
			case held && id != "":
				open[id] = true
			case !held:
				if info, err := os.Stat(path); err == nil && now.Sub(info.ModTime()) > staleAfter {
					_ = os.Remove(path)
				}
			}
		}
	}
	return open
}

// markedSession is the session the file named in claude pid's environment
// says it has open: "" when its launch named none, holds no lock on it, or
// the hook has yet to write it.
func markedSession(proc string, pid int) string {
	env, err := environ(proc, pid)
	if err != nil || env[openVar] == "" {
		return ""
	}
	id, held, err := lockedID(env[openVar])
	if err != nil || !held {
		return ""
	}
	return id
}
