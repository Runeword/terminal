package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// entry is one journal record, written as a single JSON line. The format is
// append-only on purpose: a reader's position is just a byte offset, which is
// the cheapest way to deliver "only what this session has not seen".
type entry struct {
	TS      int64  `json:"ts"`
	Session string `json:"session"`
	Label   string `json:"label"`
	Kind    string `json:"kind"` // note | edit | join | leave
	Text    string `json:"text,omitempty"`
	Path    string `json:"path,omitempty"`
}

// peer is a session's presence record, refreshed on every hook event.
type peer struct {
	Session string `json:"session"`
	Label   string `json:"label"`
	Cwd     string `json:"cwd"`
	Updated int64  `json:"updated"`
}

const (
	// Rotate rather than grow without bound. A reader whose cursor lands past
	// EOF restarts from zero, so rotation needs no cursor bookkeeping.
	maxJournalBytes = 4 << 20

	// A session counts as present if it touched the roster this recently.
	// Deliberately timestamp-based rather than PID-based: a dead session
	// lingering a few minutes in the roster is harmless, and the alternative
	// is duplicating claude-session-status's process-tree climb.
	presenceWindow = 5 * time.Minute
)

// groupPattern constrains the group name, which becomes a path component.
// "." and ".." match it and are rejected separately by validGroup.
var groupPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

func validGroup(g string) bool {
	return g != "." && g != ".." && groupPattern.MatchString(g)
}

type store struct {
	group string
	dir   string
}

// openAt builds a store rooted at a config directory. It returns nil rather
// than an error for an absent or unusable group: every caller is a hook that
// must stay silent and exit 0 when the session is not in a group.
func openAt(root, group string) *store {
	if root == "" || !validGroup(group) {
		return nil
	}
	return &store{group: group, dir: filepath.Join(root, "shared", group)}
}

func open() *store {
	return openAt(configDir(), os.Getenv("CLAUDE_CONTEXT_GROUP"))
}

// configDir resolves $CLAUDE_CONFIG_DIR — the one durable location that is
// writable inside the bubblewrap sandbox (claude-sandbox.bash binds it
// read-write) and shared by every session launched with the same instance
// number. Notably not $XDG_RUNTIME_DIR, which the sandbox replaces with a
// private tmpfs, making it invisible between sessions.
func configDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	// Hooks always inherit CLAUDE_CONFIG_DIR from the launcher, but `log` and
	// `peers` are typed into an interactive shell, which does not export it.
	// Fall back to the launcher's default instance so the human-facing commands
	// read the same journal the sessions wrote. For another instance, set
	// CLAUDE_CONFIG_DIR explicitly.
	if d := filepath.Join(h, ".claude-1"); isDir(d) {
		return d
	}
	return filepath.Join(h, ".claude")
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func (s *store) journalPath() string { return filepath.Join(s.dir, "journal.jsonl") }
func (s *store) cursorPath(id string) string {
	return filepath.Join(s.dir, "cursors", sanitize(id))
}

func (s *store) peerPath(id string) string {
	return filepath.Join(s.dir, "sessions", sanitize(id)+".json")
}

// sanitize keeps a session id usable as a filename. Ids are UUIDs in practice;
// this guards the case where one is not.
func sanitize(id string) string {
	if id == "" {
		return "_"
	}
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		}
		return '_'
	}, id)
}

// withLock serializes journal access across sessions. A dedicated lock file,
// rather than locking the journal fd, keeps rotation simple: the rename
// happens under the same lock with no append fd pointing at the renamed inode.
func (s *store) withLock(exclusive bool, fn func() error) error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(s.dir, ".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	// Nothing is written through this fd — it exists to carry the flock — so a
	// close error says nothing about whether the journal operation succeeded.
	defer func() { _ = f.Close() }()

	how := syscall.LOCK_SH
	if exclusive {
		how = syscall.LOCK_EX
	}
	if err := syscall.Flock(int(f.Fd()), how); err != nil {
		return err
	}
	defer func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }()

	return fn()
}

func (s *store) append(e entry) error {
	return s.withLock(true, func() (err error) {
		if fi, serr := os.Stat(s.journalPath()); serr == nil && fi.Size() > maxJournalBytes {
			// Keep one generation for `log`; cursors past EOF reset themselves.
			_ = os.Rename(s.journalPath(), s.journalPath()+".1")
		}
		f, err := os.OpenFile(s.journalPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return err
		}
		// Unlike the fds above, this one carries data: close can be the first
		// and only report of a failed write. Swallowing it would drop a journal
		// entry while telling the caller it was published.
		defer func() {
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}()

		b, err := json.Marshal(e)
		if err != nil {
			return err
		}
		_, err = f.Write(append(b, '\n'))
		return err
	})
}

// readSince returns the entries after byte offset off, and the offset to store
// for next time. Only whole lines are consumed, so an append that lands
// mid-read is picked up on the following call rather than parsed torn.
//
// An offset past EOF means the journal rotated under us; restart from the
// beginning. Re-delivering one digest is a better failure than going silent.
func (s *store) readSince(off int64) (es []entry, next int64, err error) {
	next = off
	err = s.withLock(false, func() error {
		f, e := os.Open(s.journalPath())
		if e != nil {
			if os.IsNotExist(e) {
				next = 0
				return nil
			}
			return e
		}
		// Read-only fd: a close error cannot invalidate bytes already read.
		defer func() { _ = f.Close() }()

		fi, e := f.Stat()
		if e != nil {
			return e
		}
		if off < 0 || off > fi.Size() {
			off = 0
		}
		if _, e = f.Seek(off, io.SeekStart); e != nil {
			return e
		}
		b, e := io.ReadAll(f)
		if e != nil {
			return e
		}

		i := bytes.LastIndexByte(b, '\n')
		if i < 0 {
			next = off
			return nil
		}
		next = off + int64(i) + 1

		for _, line := range bytes.Split(b[:i], []byte{'\n'}) {
			if len(bytes.TrimSpace(line)) == 0 {
				continue
			}
			var en entry
			if json.Unmarshal(line, &en) != nil {
				continue // skip a corrupt line rather than losing the rest
			}
			es = append(es, en)
		}
		return nil
	})
	return es, next, err
}

func (s *store) cursor(id string) int64 {
	b, err := os.ReadFile(s.cursorPath(id))
	if err != nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func (s *store) setCursor(id string, off int64) {
	if os.MkdirAll(filepath.Dir(s.cursorPath(id)), 0o700) != nil {
		return
	}
	writeAtomic(s.cursorPath(id), []byte(strconv.FormatInt(off, 10)))
}

func (s *store) touch(p peer) {
	if os.MkdirAll(filepath.Dir(s.peerPath(p.Session)), 0o700) != nil {
		return
	}
	p.Updated = time.Now().Unix()
	b, err := json.Marshal(p)
	if err != nil {
		return
	}
	writeAtomic(s.peerPath(p.Session), b)
}

// selfPeer returns this session's own roster record, written by the hooks.
// `note` uses it so a note is attributed the same way as the session's edits,
// whatever directory the model happened to run the command from.
func (s *store) selfPeer(id string) (peer, bool) {
	b, err := os.ReadFile(s.peerPath(id))
	if err != nil {
		return peer{}, false
	}
	var p peer
	if json.Unmarshal(b, &p) != nil || p.Label == "" {
		return peer{}, false
	}
	return p, true
}

func (s *store) drop(id string) {
	_ = os.Remove(s.peerPath(id))
	_ = os.Remove(s.cursorPath(id))
}

// peers lists sessions other than self that are currently present, pruning
// stale records as it finds them.
func (s *store) peers(self string, now time.Time) []peer {
	ents, _ := os.ReadDir(filepath.Join(s.dir, "sessions"))
	var out []peer
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		full := filepath.Join(s.dir, "sessions", e.Name())
		b, err := os.ReadFile(full)
		if err != nil {
			continue
		}
		var p peer
		if json.Unmarshal(b, &p) != nil {
			continue
		}
		if now.Sub(time.Unix(p.Updated, 0)) > presenceWindow {
			_ = os.Remove(full)
			continue
		}
		if p.Session == self {
			continue
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Label < out[j].Label })
	return out
}

func writeAtomic(path string, b []byte) {
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if os.WriteFile(tmp, b, 0o600) != nil {
		return
	}
	if os.Rename(tmp, path) != nil {
		_ = os.Remove(tmp)
	}
}
