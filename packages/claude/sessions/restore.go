package main

// restore is the picker behind __claude_sessions_restore
// (sources/.config/shell/functions/claude.bash), which selects as ga's file
// picker does (packages/git/hunk-pick, picker.go): one fzf showing either the
// backups or, drilled into one, those of its sessions that can be resumed.
// start lists the backups into the picker's state directory, the bindings
// call key and load, which print fzf actions, the preview calls show, and
// picked prints the sessions the picker ended with, for the shell to resume.
//
// A backup marked with Tab stands for all its sessions. A drill (Enter,
// Right) opens a backup's sessions with those it stands for marked, and a
// return (Left, Esc) records the marks as they are, the backup marked when
// any is. Enter in the sessions list, or on a backup with none to resume,
// ends the picker with what is marked; Esc in the backups list cancels it,
// or turns the search on while it is off, as the global esc does. A reload
// wipes fzf's own marks, so a drill saves the backups list's marks and query,
// and each switch queues what must land with the new list (marks, cursor,
// query) for load, which fzf runs before it paints the reloaded list.
//
// Files in the state directory that shell commands read stay plain:
//
//	backups   the backups list, which fzf starts with and a return reloads
//	sessions  the drilled backup's sessions, which a drill reloads
//	query     the backups list's query saved at a drill; a return restores it
//
// state.json holds the rest (see restoreState).

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// restoreState is what start found, then the picker's own state, rewritten
// by key and load.
type restoreState struct {
	// Open is the sessions open when start ran, which no backup resumes.
	Open []string `json:"open,omitempty"`
	// Backups is the backups listed, newest first.
	Backups []restoreBackup `json:"backups"`
	// Drill names the backup whose sessions are listed; empty while the
	// backups are.
	Drill string `json:"drill,omitempty"`
	// Picks maps a backup to its sessions a drill left marked, by id, when
	// that was some of them only. A backup without is whole iff marked.
	Picks map[string][]string `json:"picks,omitempty"`
	// Marks is the backups list's selection when the current drill started:
	// the reload that lists the sessions wipes fzf's own marks.
	Marks []string `json:"marks,omitempty"`
	// Pending is the list switch key requested. load commits it once the
	// reloaded list is in, so a key pressed before then still acts on the
	// list on screen.
	Pending *restoreSwitch `json:"pending,omitempty"`
	// Accepted is the backups marked when the picker ended: empty when none
	// was, or the picker was cancelled.
	Accepted []string `json:"accepted,omitempty"`
}

// restoreBackup is a backup as the picker shows it.
type restoreBackup struct {
	Name string `json:"name"`
	// Sessions is those of its sessions that can be resumed, in its order,
	// and Rows their rows in the sessions list.
	Sessions []savedSession `json:"sessions,omitempty"`
	Rows     []string       `json:"rows,omitempty"`
	// Shown is its preview: those sessions, each led by how long ago its
	// conversation was last active, then, dimmed, the ones left out, each
	// led by why.
	Shown string `json:"shown"`
	// Left says why each session left out is, for picked.
	Left []leftOut `json:"-"`
}

// leftOut is a session of a backup that can't be resumed, and the note that
// says why.
type leftOut struct{ id, note string }

// restoreSwitch is what must land with the reloaded list, kept as data that
// load renders as fzf actions: no text from state.json reaches fzf as an
// action (execute runs a command).
type restoreSwitch struct {
	Drill        string `json:"drill,omitempty"`        // backup drilled into; empty for the backups list
	ClearQuery   bool   `json:"clearQuery,omitempty"`   // clear the query before marking rows
	SelectAll    bool   `json:"selectAll,omitempty"`    // mark every row
	Select       []int  `json:"select,omitempty"`       // 1-based rows to mark
	Cursor       int    `json:"cursor,omitempty"`       // 1-based row for the cursor; a drill starts at the first
	RestoreQuery bool   `json:"restoreQuery,omitempty"` // bring back the saved backups query, tracking the cursor's row
}

// restorer runs the picker's steps against state directory dir. getenv is
// os.Getenv, faked in tests.
type restorer struct {
	dir    string
	getenv func(string) string
}

func (r restorer) path(name string) string { return filepath.Join(r.dir, name) }

func (r restorer) loadState() (restoreState, error) {
	var st restoreState
	data, err := os.ReadFile(r.path("state.json"))
	if err != nil {
		return st, err
	}
	return st, json.Unmarshal(data, &st)
}

// saveState replaces state.json through a rename: the preview reads it while
// keys rewrite it.
func (r restorer) saveState(st restoreState) error {
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	tmp := r.path("state.json.tmp")
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.path("state.json"))
}

// listed is the listed backup named name.
func (st restoreState) listed(name string) (restoreBackup, bool) {
	i := slices.IndexFunc(st.Backups, func(b restoreBackup) bool { return b.Name == name })
	if i < 0 {
		return restoreBackup{}, false
	}
	return st.Backups[i], true
}

// start lists the backups in dir into the state directory, newest first,
// each line how long ago and when it was made, how many sessions it holds
// and their directories, and saves what the picker shows of each. It leaves
// out, with a note, a backup it can't read.
func (r restorer) start(notes io.Writer, h host, dir string, now time.Time) error {
	names, err := backups(dir)
	if errors.Is(err, fs.ErrNotExist) || err == nil && len(names) == 0 {
		return errors.New("no backup yet")
	}
	if err != nil {
		return err
	}
	open := openSessionIDs(notes, h, now)
	var st restoreState
	for id := range open {
		st.Open = append(st.Open, id)
	}
	slices.Sort(st.Open)
	type row struct{ sessions, dirs string }
	var rows []row
	width := 0
	for i := len(names) - 1; i >= 0; i-- {
		b, err := readBackup(h.home, filepath.Join(dir, names[i]))
		if err != nil {
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out a backup: %v\n", err)
			continue
		}
		var dirs []string
		for _, s := range b.Sessions {
			if d := clean(tilde(h.home, s.Cwd)); !slices.Contains(dirs, d) {
				dirs = append(dirs, d)
			}
		}
		rw := row{sessions: count(len(b.Sessions), "session"), dirs: strings.Join(dirs, ", ")}
		width = max(width, utf8.RuneCountInString(rw.sessions))
		rows = append(rows, rw)
		st.Backups = append(st.Backups, restoreBackupOf(h.home, open, names[i], b, now))
	}
	if len(rows) == 0 {
		return errors.New("no backup can be read")
	}
	var list strings.Builder
	for i, rw := range rows {
		t := backupTime(st.Backups[i].Name)
		line := pad(age(now.Sub(t)), 4) + "  " + t.Local().Format("Mon _2 Jan 15:04") + "  " + pad(rw.sessions, width) + "  " + rw.dirs
		list.WriteString(strings.TrimRight(line, " ") + "\n")
	}
	if err := os.WriteFile(r.path("backups"), []byte(list.String()), 0o600); err != nil {
		return err
	}
	return r.saveState(st)
}

// openSessionIDs is the sessions open now: those a held lock names or a
// running claude has. It says on notes when it can't look for the claudes.
func openSessionIDs(notes io.Writer, h host, now time.Time) map[string]bool {
	open := openByLock(h.home, now)
	_, found, err := h.claudes()
	if err != nil {
		_, _ = fmt.Fprintf(notes, "claude-sessions: %v; a session still open would be started twice\n", err)
	}
	for _, c := range found {
		if c.id != "" {
			open[c.id] = true
		}
	}
	return open
}

// restoreBackupOf is backup b, named name, as the picker shows it, open being
// the sessions open now. A session it holds twice counts once, as it first
// holds it.
func restoreBackupOf(home string, open map[string]bool, name string, b backupFile, now time.Time) restoreBackup {
	rb := restoreBackup{Name: name}
	var left []savedSession
	leads := map[string]string{}
	for _, s := range b.Sessions {
		if _, seen := leads[s.ID]; seen {
			continue
		}
		lead, why := verdict(home, open, s, now)
		leads[s.ID] = lead
		if why == "" {
			rb.Sessions = append(rb.Sessions, s)
			continue
		}
		left = append(left, s)
		rb.Left = append(rb.Left, leftOut{s.ID, fmt.Sprintf("left out %q (%s): %s", s.Title, tilde(home, s.Cwd), why)})
	}
	lead := func(s savedSession) string { return pad(leads[s.ID], 4) + "  " }
	var rows bytes.Buffer
	writeRows(&rows, home, rb.Sessions, lead)
	rb.Rows = lines(rows.String())
	// Those left out may hold what a row can't: only text that is clean
	// reaches the preview.
	shown := slices.Clone(rb.Sessions)
	for _, s := range left {
		conns := make([]string, len(s.Connections))
		for i, c := range s.Connections {
			conns[i] = clean(c)
		}
		s.Cwd, s.Title, s.Connections = clean(s.Cwd), clean(s.Title), conns
		shown = append(shown, s)
	}
	var previewed bytes.Buffer
	writeRows(&previewed, home, shown, lead)
	all := lines(previewed.String())
	for i := len(rb.Sessions); i < len(all); i++ {
		all[i] = dim + all[i] + reset
	}
	if len(all) > 0 {
		rb.Shown = strings.Join(all, "\n") + "\n"
	}
	return rb
}

// verdict is what leads session s's row in a backup's preview, and why it
// can't be resumed, "" when it can: then its row is led by how long ago its
// conversation was last active. One open now (in open) can't, nor one whose
// conversation or directory is gone, nor one the backup can't say how to
// start: in a profile __claude doesn't start, under what is no session id, or
// with a field a row can't hold.
func verdict(home string, open map[string]bool, s savedSession, now time.Time) (lead, why string) {
	n, ok := instance(home, s.Config)
	fields := s.Cwd + s.NetAllow + s.TmuxSession + s.Title + strings.Join(s.Connections, "") + strings.Join(s.Plugins, "")
	if !ok || !uuidRE.MatchString(s.ID) || !rowSafe(fields) {
		return "?", "the backup can't say how to start it"
	}
	paths, err := transcripts(s.Config, s.ID)
	switch {
	case open[s.ID]:
		return "open", "it is open"
	case err != nil:
		return "gone", "its conversation is gone from profile " + n
	case !isDir(s.Cwd):
		return "gone", "its directory is gone"
	}
	st, err := os.Stat(paths[0])
	if err != nil {
		return "?", ""
	}
	return age(now.Sub(st.ModTime())), ""
}

// lines is the lines of s, each without its newline.
func lines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

// shellQuote quotes s for the sh -c that fzf runs action commands through.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// key returns the fzf actions for enter, right, left or esc, whose meaning
// depends on the list shown. focus is the focused row's index ({n}), empty
// when no row is; sel ({+n}) are the marked rows' indices, which fall back to
// the focused row when none is marked, so FZF_SELECT_COUNT gates them.
//
// Switching lists is a reload-sync of the other one: it keeps the current list
// up until the new one is read. What must land with the new list (marks,
// cursor, query) is queued for load, which fzf runs before painting the
// reloaded list, so a switch is one frame.
func (r restorer) key(key, focus string, sel []int) (string, error) {
	st, err := r.loadState()
	if err != nil {
		return "", err
	}
	if count, _ := strconv.Atoi(r.getenv("FZF_SELECT_COUNT")); count == 0 {
		sel = nil
	}
	if st.Drill != "" {
		return r.sessionsKey(st, key, sel)
	}
	return r.backupsKey(st, key, focus, sel)
}

func (r restorer) backupsKey(st restoreState, key, focus string, sel []int) (string, error) {
	switch key {
	case "left":
		return "backward-char", nil
	case "esc":
		// The global esc (FZF_DEFAULT_OPTS): abort from search mode; from nav
		// mode, back to search, the toggle alt-i is bound to.
		if s := r.getenv("FZF_INPUT_STATE"); s == "" || s == "enabled" {
			return "abort", nil
		}
		return "trigger(alt-i)", nil
	case "enter", "right":
	default:
		return "", nil
	}
	i, err := strconv.Atoi(focus)
	if err != nil || i < 0 || i >= len(st.Backups) {
		return "", nil
	}
	var marks []string
	for _, n := range sel {
		if n >= 0 && n < len(st.Backups) {
			marks = append(marks, st.Backups[n].Name)
		}
	}
	b := st.Backups[i]
	if len(b.Sessions) == 0 {
		// None to resume: Enter ends the picker with the backups marked, to
		// which this one adds nothing; Right does nothing.
		if key == "right" {
			return "", nil
		}
		return r.accept(st, marks)
	}

	// Drill: save what the backups list needs back, and queue the sessions
	// list's marks: the picks a drill left, or every session of a marked
	// backup without, so a drill can't silently drop it.
	picks, some := st.Picks[b.Name]
	sw := restoreSwitch{Drill: b.Name, SelectAll: !some && slices.Contains(marks, b.Name)}
	for n, s := range b.Sessions {
		if slices.Contains(picks, s.ID) {
			sw.Select = append(sw.Select, n+1)
		}
	}
	query := r.getenv("FZF_QUERY")
	sw.ClearQuery = query != ""
	for name, data := range map[string]string{"sessions": strings.Join(b.Rows, "\n") + "\n", "query": query} {
		if err := os.WriteFile(r.path(name), []byte(data), 0o600); err != nil {
			return "", err
		}
	}
	st.Marks, st.Pending = marks, &sw
	if err := r.saveState(st); err != nil {
		return "", err
	}
	return "reload-sync(cat " + shellQuote(r.path("sessions")) + ")", nil
}

func (r restorer) sessionsKey(st restoreState, key string, sel []int) (string, error) {
	switch key {
	case "right":
		return "forward-char", nil
	case "enter", "left", "esc":
	default:
		return "", nil
	}
	b, ok := st.listed(st.Drill)
	if !ok {
		return "", fmt.Errorf("no backup %q listed", st.Drill)
	}
	// Record the marks as shown: every session marked is the whole backup,
	// some of them those, none the backup unmarked.
	var ids []string
	for _, n := range sel {
		if n >= 0 && n < len(b.Sessions) {
			ids = append(ids, b.Sessions[n].ID)
		}
	}
	delete(st.Picks, b.Name)
	if len(ids) > 0 && len(ids) < len(b.Sessions) {
		if st.Picks == nil {
			st.Picks = map[string][]string{}
		}
		st.Picks[b.Name] = ids
	}
	// The backups marked before the drill, with the drilled one in or out
	// by its marks.
	marked := slices.DeleteFunc(slices.Clone(st.Marks), func(m string) bool { return m == b.Name })
	if len(ids) > 0 {
		marked = append(marked, b.Name)
	}
	if key == "enter" {
		return r.accept(st, marked)
	}

	// Back to the backups list. Marks are restored by position while the
	// query is empty (every backup listed, in order); then the saved query
	// comes back with the cursor tracking the drilled backup.
	sw := restoreSwitch{ClearQuery: r.getenv("FZF_QUERY") != ""}
	for n, bk := range st.Backups {
		if slices.Contains(marked, bk.Name) {
			sw.Select = append(sw.Select, n+1)
		}
		if bk.Name == b.Name {
			sw.Cursor = n + 1
		}
	}
	q, _ := os.ReadFile(r.path("query"))
	sw.RestoreQuery = len(q) > 0
	st.Pending = &sw
	if err := r.saveState(st); err != nil {
		return "", err
	}
	return "reload-sync(cat " + shellQuote(r.path("backups")) + ")", nil
}

// accept ends the picker with the backups marked.
func (r restorer) accept(st restoreState, marked []string) (string, error) {
	st.Accepted = marked
	return "accept", r.saveState(st)
}

// load commits the switch key requested and returns the actions it queued.
// fzf runs it on every load event, once a reload has read the whole list,
// and paints that list only after these actions ran.
func (r restorer) load() (string, error) {
	st, err := r.loadState()
	if err != nil || st.Pending == nil {
		return "", err
	}
	sw := *st.Pending
	st.Drill, st.Pending = sw.Drill, nil
	return r.actions(sw), r.saveState(st)
}

// actions renders sw as fzf actions: the query cleared, the marks, the
// cursor, then the saved backups query back.
func (r restorer) actions(sw restoreSwitch) string {
	var a []string
	if sw.ClearQuery {
		a = append(a, "change-query()", "wait")
	}
	if sw.SelectAll {
		a = append(a, "select-all")
	}
	for _, n := range sw.Select {
		a = append(a, "pos("+strconv.Itoa(n)+")", "select")
	}
	switch {
	case sw.Drill != "":
		a = append(a, "first")
	case sw.Cursor > 0:
		a = append(a, "pos("+strconv.Itoa(sw.Cursor)+")")
	}
	if sw.RestoreQuery {
		restore := "transform-query(cat " + shellQuote(r.path("query")) + ")"
		a = append(a, "track-current", restore, "wait", "untrack-current")
	}
	return strings.Join(a, "+")
}

// show writes the preview of row n ({n}) of the list shown: what a backup
// holds, led by the sessions a drill picked of it when it picked some only,
// or a session's conversation, width columns wide.
func (r restorer) show(w *bytes.Buffer, n string, width int, now time.Time) error {
	st, err := r.loadState()
	if err != nil {
		return err
	}
	i, err := strconv.Atoi(n)
	if err != nil || i < 0 {
		return nil
	}
	if st.Drill == "" {
		if i >= len(st.Backups) {
			return nil
		}
		b := st.Backups[i]
		// Whole backups need no hint: fzf's own marker shows them.
		if picks := st.Picks[b.Name]; len(picks) > 0 {
			var rows []string
			for j, s := range b.Sessions {
				if slices.Contains(picks, s.ID) {
					rows = append(rows, strconv.Itoa(j+1))
				}
			}
			w.WriteString("◐ sessions: " + strings.Join(rows, " ") + "\n")
		}
		w.WriteString(b.Shown)
		return nil
	}
	b, ok := st.listed(st.Drill)
	if !ok || i >= len(b.Sessions) {
		return nil
	}
	return preview(w, b.Sessions[i].Config, b.Sessions[i].ID, width, now)
}

// picked writes the sessions the picker ended with, for the shell to resume,
// as the backups in dir hold them: of each backup accepted, those a drill
// picked, else every one that can be resumed. The newest backup's come
// first, each backup's in its order, and a session several hold comes once,
// as the newest of them saved it. A row: the session's id, its profile's
// number, its directory, its connections, its CLAUDE_SANDBOX_NET_ALLOW, its
// plugins (the lists comma-separated) and its tmux session, each "-" when it
// has none, then its title, a tab apart. It says on notes why it leaves out a
// session of a whole backup, and a backup gone since start listed it.
func (r restorer) picked(out, notes io.Writer, home, dir string, now time.Time) error {
	st, err := r.loadState()
	if err != nil {
		return err
	}
	names, err := backups(dir)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	for _, name := range st.Accepted {
		if !slices.Contains(names, name) {
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out backup %q: it is gone\n", name)
		}
	}
	open := map[string]bool{}
	for _, id := range st.Open {
		open[id] = true
	}
	var w bytes.Buffer
	resumed := map[string]bool{}
	var left []leftOut
	for i := len(names) - 1; i >= 0; i-- {
		if !slices.Contains(st.Accepted, names[i]) {
			continue
		}
		b, err := readBackup(home, filepath.Join(dir, names[i]))
		if err != nil {
			return err
		}
		rb := restoreBackupOf(home, open, names[i], b, now)
		picks, some := st.Picks[names[i]]
		for _, s := range rb.Sessions {
			if resumed[s.ID] || some && !slices.Contains(picks, s.ID) {
				continue
			}
			resumed[s.ID] = true
			n, _ := instance(home, s.Config)
			w.WriteString(strings.Join([]string{
				s.ID, n, s.Cwd,
				orNone(strings.Join(s.Connections, ",")), orNone(s.NetAllow), orNone(strings.Join(s.Plugins, ",")),
				orNone(s.TmuxSession), s.Title,
			}, "\t") + "\n")
		}
		if !some {
			left = append(left, rb.Left...)
		}
	}
	noted := map[string]bool{}
	for _, l := range left {
		if !resumed[l.id] && !noted[l.id] {
			noted[l.id] = true
			_, _ = fmt.Fprintln(notes, "claude-sessions: "+l.note)
		}
	}
	_, err = w.WriteTo(out)
	return err
}

// indices reads fzf's {+n}, a word per row; an empty word is none.
func indices(words []string) ([]int, error) {
	var sel []int
	for _, w := range words {
		if w == "" {
			continue
		}
		n, err := strconv.Atoi(w)
		if err != nil {
			return nil, fmt.Errorf("invalid index %q", w)
		}
		sel = append(sel, n)
	}
	return sel, nil
}
