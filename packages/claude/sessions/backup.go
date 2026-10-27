package main

// backup saves the sessions open on this machine, and saved lists them again
// for __claude_sessions_restore, which starts each as it was started: in its
// profile and directory, with its connections and plugins, in its tmux
// session.
//
// Claude Code keeps a registry of the sessions it runs, sessions/<pid>.json in
// each profile: the session each claude has open, rewritten as /clear and
// /resume change it, its directory, and when the process started, which tells
// a live entry from one a claude left behind. On macOS backup reads it
// (registryClaudes). On Linux it can't: the registry names each entry after
// the PID claude has in its own PID namespace, and every claude the sandbox
// launcher starts is PID 2 in a namespace of its own, so the sessions
// overwrite one another's entry and `claude agents --json` lists none of them.
// There backup asks the processes, through /proc (procClaudes): every claude
// this user runs in a terminal, its profile, its directory and how it was
// launched. Which session one has open no file there says, but claude starts
// each process with it, as CLAUDE_CODE_SESSION_ID: the status line every
// refreshInterval (2s in sources/.claude/settings.json), hooks, the Bash
// tool's shell. backup watches for one.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const (
	// sessionVar names the session in the environment of what claude starts.
	sessionVar = "CLAUDE_CODE_SESSION_ID"
	// lookFor is how long backup watches for a claude to start a process,
	// and lookEvery how often it looks: the status line runs for a few
	// milliseconds every refreshInterval.
	lookFor   = 5 * time.Second
	lookEvery = 5 * time.Millisecond
	// maxBackups is how many backups backup keeps, the newest.
	maxBackups = 20
	// none stands for an empty field in a row of saved: the shell's read
	// merges a run of tabs into one, which would shift the fields after it.
	none = "-"
)

// backupFile is a backup: when it was made and the sessions open then.
type backupFile struct {
	Version  int            `json:"version"`
	Time     time.Time      `json:"time"`
	Sessions []savedSession `json:"sessions"`
}

// savedSession is an open session and how __claude started it: its profile
// (CLAUDE_CONFIG_DIR, $HOME/.claude-<n>), its directory, the credentials the
// sandbox launcher handed it (gh, jira, firebase), the hosts its network
// filter added (CLAUDE_SANDBOX_NET_ALLOW), its plugins by name, and the tmux
// session and window its pane was in.
type savedSession struct {
	ID          string   `json:"id"`
	Config      string   `json:"config"`
	Cwd         string   `json:"cwd"`
	Title       string   `json:"title"`
	Connections []string `json:"connections,omitempty"`
	NetAllow    string   `json:"netAllow,omitempty"`
	Plugins     []string `json:"plugins,omitempty"`
	TmuxSession string   `json:"tmuxSession,omitempty"`
	TmuxWindow  int      `json:"tmuxWindow,omitempty"`
}

// connections are the credentials a session can be handed: the name a row
// carries for each, and the launcher's variable that hands it.
var connections = []struct{ name, flag string }{
	{"gh", "CLAUDE_SANDBOX_ALLOW_GH"},
	{"jira", "CLAUDE_SANDBOX_ALLOW_JIRA"},
	{"firebase", "CLAUDE_SANDBOX_ALLOW_FIREBASE"},
}

// host is where backup finds the open sessions. On Linux: the /proc it reads,
// the user whose sessions they are, how many times it looks for a claude to
// start a process and what passes the time between two looks. Elsewhere proc
// is "", and ps lists the processes, for the registry. Everywhere: $HOME,
// which holds the profiles, and the tmux panes.
type host struct {
	proc  string
	uid   uint32
	looks int
	wait  func()
	ps    func() ([]byte, error)
	home  string
	panes func() map[int]pane
}

func defaultHost() (host, error) {
	home, err := os.UserHomeDir()
	h := host{home: home, panes: tmuxPanes, ps: psTable}
	if runtime.GOOS == "linux" {
		h.proc, h.uid = "/proc", uint32(os.Getuid())
		h.looks, h.wait = int(lookFor/lookEvery), func() { time.Sleep(lookEvery) }
	}
	return h, err
}

// pane is a tmux pane: its session, its window's index, and the command it
// was started with, as tmux quotes it.
type pane struct {
	session string
	window  int
	start   string
}

// tmuxPanes is every pane of the tmux server this runs under, by the PID of
// the process the pane started; none outside tmux.
func tmuxPanes() map[int]pane {
	if os.Getenv("TMUX") == "" {
		return nil
	}
	out, err := exec.Command("tmux", "list-panes", "-a", "-F", "#{pane_pid}\t#{window_index}\t#{session_name}\t#{pane_start_command}").Output()
	if err != nil {
		return nil
	}
	panes := map[int]pane{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.SplitN(line, "\t", 4)
		if len(f) != 4 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		window, err2 := strconv.Atoi(f[1])
		if err1 == nil && err2 == nil {
			panes[pid] = pane{session: f[2], window: window, start: f[3]}
		}
	}
	return panes
}

// psTable lists every process for registryClaudes: its PID and its parent's,
// when it started, as Claude Code records it (procStart: `ps -o lstart=` in
// the C locale and UTC), and its arguments, unabridged.
func psTable() ([]byte, error) {
	cmd := exec.Command("ps", "-A", "-ww", "-o", "pid=,ppid=,lstart=,command=")
	cmd.Env = append(os.Environ(), "LC_ALL=C", "TZ=UTC") // the last of a name wins
	return cmd.Output()
}

// procStat is the part of /proc/<pid>/stat backup reads, and the user its
// directory belongs to: the process's, or root for one that can't be
// inspected (not dumpable).
type procStat struct {
	comm  string
	state byte
	ppid  int
	tty   int
	uid   uint32
}

// stopped reports whether the process is stopped (Ctrl-Z, a debugger): it
// starts nothing until it runs again.
func (st procStat) stopped() bool {
	return st.state == 'T' || st.state == 't'
}

// procFile is the path of file name of process pid.
func procFile(proc string, pid int, name ...string) string {
	return filepath.Join(append([]string{proc, strconv.Itoa(pid)}, name...)...)
}

// readStat reads the stat of process pid. Its name sits between the first
// "(" and the last ")", since it can hold either, or a space.
func readStat(proc string, pid int) (procStat, error) {
	data, err := os.ReadFile(procFile(proc, pid, "stat"))
	if err != nil {
		return procStat{}, err
	}
	open, shut := bytes.IndexByte(data, '('), bytes.LastIndexByte(data, ')')
	if open < 0 || shut < open {
		return procStat{}, fmt.Errorf("process %d: unreadable stat", pid)
	}
	// After the name: state ppid pgrp session tty_nr …
	f := strings.Fields(string(data[shut+1:]))
	if len(f) < 5 || len(f[0]) != 1 {
		return procStat{}, fmt.Errorf("process %d: unreadable stat", pid)
	}
	ppid, err1 := strconv.Atoi(f[1])
	tty, err2 := strconv.Atoi(f[4])
	if err1 != nil || err2 != nil {
		return procStat{}, fmt.Errorf("process %d: unreadable stat", pid)
	}
	return procStat{comm: string(data[open+1 : shut]), state: f[0][0], ppid: ppid, tty: tty}, nil
}

// processes is the stat of every process, by PID. One that exits while this
// reads is left out.
func processes(proc string) (map[int]procStat, error) {
	entries, err := os.ReadDir(proc)
	if err != nil {
		return nil, err
	}
	ps := map[int]procStat{}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid <= 0 {
			continue
		}
		info, err := os.Stat(procFile(proc, pid))
		if err != nil {
			continue
		}
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !ok {
			continue
		}
		if st, err := readStat(proc, pid); err == nil {
			st.uid = owner.Uid
			ps[pid] = st
		}
	}
	return ps, nil
}

// isClaude reports whether a process is the claude CLI: the native build's
// name, or .claude-wrapped, which the nixpkgs wrapper execs.
func isClaude(st procStat) bool {
	return st.comm == "claude" || st.comm == ".claude-wrapped"
}

// terminalClaudes is the claude processes user uid runs in a terminal, by
// PID. A claude a claude started is left out (`claude -p` in the Bash tool,
// an MCP server), and so are one with no terminal (the background agents'
// daemon) and one that has exited.
func terminalClaudes(ps map[int]procStat, uid uint32) []int {
	var pids []int
	for pid, st := range ps {
		if isClaude(st) && st.uid == uid && st.tty != 0 && st.state != 'Z' && st.state != 'X' && !claudeAbove(ps, st.ppid) {
			pids = append(pids, pid)
		}
	}
	slices.Sort(pids)
	return pids
}

// claudeAbove reports whether process pid, or a process above it, is a
// claude. The table is read while processes come and go, so the walk stops
// after as many steps as it has entries.
func claudeAbove(ps map[int]procStat, pid int) bool {
	for steps := 0; steps < len(ps); steps++ {
		st, ok := ps[pid]
		if !ok {
			return false
		}
		if isClaude(st) {
			return true
		}
		pid = st.ppid
	}
	return false
}

// paneOf is the tmux pane process pid runs in: the pane started it, or a
// process above it (the sandbox launcher, which execs bwrap).
func paneOf(ps map[int]procStat, panes map[int]pane, pid int) (pane, bool) {
	for steps := 0; steps <= len(ps); steps++ {
		if p, ok := panes[pid]; ok {
			return p, true
		}
		st, ok := ps[pid]
		if !ok {
			break
		}
		pid = st.ppid
	}
	return pane{}, false
}

// environ is process pid's environment, by name.
func environ(proc string, pid int) (map[string]string, error) {
	data, err := os.ReadFile(procFile(proc, pid, "environ"))
	if err != nil {
		return nil, err
	}
	env := map[string]string{}
	for _, kv := range strings.Split(string(data), "\x00") {
		if k, v, ok := strings.Cut(kv, "="); ok && k != "" {
			env[k] = v
		}
	}
	return env, nil
}

// cmdline is process pid's arguments.
func cmdline(proc string, pid int) ([]string, error) {
	data, err := os.ReadFile(procFile(proc, pid, "cmdline"))
	if err != nil {
		return nil, err
	}
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00"), nil
}

// children is the running processes pid started. Linux lists them for each
// thread; claude starts its children on its main thread, whose list this
// reads. A kernel built without these lists has each process's parent in its
// stat, which this reads instead.
func children(proc string, pid int) ([]int, error) {
	data, err := os.ReadFile(procFile(proc, pid, "task", strconv.Itoa(pid), "children"))
	if errors.Is(err, fs.ErrNotExist) {
		if _, err := os.Stat(procFile(proc, pid)); err != nil {
			return nil, err
		}
		ps, err := processes(proc)
		if err != nil {
			return nil, err
		}
		var kids []int
		for kid, st := range ps {
			if st.ppid == pid {
				kids = append(kids, kid)
			}
		}
		return kids, nil
	}
	if err != nil {
		return nil, err
	}
	var kids []int
	for _, f := range strings.Fields(string(data)) {
		if kid, err := strconv.Atoi(f); err == nil {
			kids = append(kids, kid)
		}
	}
	return kids, nil
}

// sessionIDs finds the session each claude of pids has open: the
// CLAUDE_CODE_SESSION_ID of a process it starts while this looks. One it
// started before is passed over: an MCP or LSP server keeps the session of the
// day it started, which /clear or /resume may since have replaced. A claude
// that exits, or is stopped, is given up on.
func (h host) sessionIDs(pids []int) map[int]string {
	ids := map[int]string{}
	before := map[int]map[int]bool{} // the children each claude had at the first look
	left := slices.Clone(pids)
	for look := 0; look < h.looks && len(left) > 0; look++ {
		if look > 0 {
			h.wait()
		}
		var still []int
		for _, pid := range left {
			st, err := readStat(h.proc, pid)
			if err != nil || st.stopped() {
				continue
			}
			kids, err := children(h.proc, pid)
			if err != nil {
				continue
			}
			if look == 0 {
				before[pid] = map[int]bool{}
				for _, kid := range kids {
					before[pid][kid] = true
				}
			} else if id := newSession(h.proc, kids, before[pid]); id != "" {
				ids[pid] = id
				continue
			}
			still = append(still, pid)
		}
		left = still
	}
	return ids
}

// newSession is the session named in the environment of one of kids that
// before doesn't hold, "" while none does: a child that names none may not
// have exec'd yet, so it is read again at the next look.
func newSession(proc string, kids []int, before map[int]bool) string {
	for _, kid := range kids {
		if before[kid] {
			continue
		}
		if env, err := environ(proc, kid); err == nil && uuidRE.MatchString(env[sessionVar]) {
			return env[sessionVar]
		}
	}
	return ""
}

// claudeProc is a claude run in a terminal, and what backup learned of it:
// the session it has open, its profile (CLAUDE_CONFIG_DIR), its directory, its
// plugins, and the credentials it was handed, with the extra hosts of its
// network filter. Where its environment can't be read (macOS shows no other
// process's), connsFromPane says to take the credentials from the command its
// tmux pane was started with. err says why it can't be saved.
type claudeProc struct {
	pid           int
	id            string
	config        string
	cwd           string
	plugins       []string
	conns         []string
	netAllow      string
	connsFromPane bool
	err           error
}

// claudes is the process table and the claudes run in a terminal.
func (h host) claudes() (map[int]procStat, []claudeProc, error) {
	if h.proc != "" {
		return h.procClaudes()
	}
	return h.registryClaudes()
}

// procClaudes reads the claudes from /proc. The session each has open is the
// one its launch's file names (open.go), else the one a process it starts
// names: only a claude whose launch named none is watched for one.
func (h host) procClaudes() (map[int]procStat, []claudeProc, error) {
	ps, err := processes(h.proc)
	if err != nil {
		return nil, nil, fmt.Errorf("finding the open sessions reads %s: %w", h.proc, err)
	}
	pids := terminalClaudes(ps, h.uid)
	ids := map[int]string{}
	var unmarked []int
	for _, pid := range pids {
		if id := markedSession(h.proc, pid); id != "" {
			ids[pid] = id
			continue
		}
		unmarked = append(unmarked, pid)
	}
	for pid, id := range h.sessionIDs(unmarked) {
		ids[pid] = id
	}
	found := make([]claudeProc, len(pids))
	for i, pid := range pids {
		found[i] = h.procClaude(pid, ids[pid])
	}
	return ps, found, nil
}

// procClaude is what /proc says of claude pid, whose session is id ("" when
// none was found).
func (h host) procClaude(pid int, id string) claudeProc {
	c := claudeProc{pid: pid, id: id}
	if c.cwd, c.err = os.Readlink(procFile(h.proc, pid, "cwd")); c.err != nil {
		return c
	}
	if id == "" {
		c.err = fmt.Errorf("it started no process in %s that names its session (its status line runs every refreshInterval)", lookFor)
		if st, err := readStat(h.proc, pid); err == nil && st.stopped() {
			c.err = errors.New("it is stopped; bring it back (fg), then back up again")
		}
		return c
	}
	env, err := environ(h.proc, pid)
	if err != nil {
		c.err = err
		return c
	}
	args, err := cmdline(h.proc, pid)
	if err != nil {
		c.err = err
		return c
	}
	c.config, c.plugins, c.netAllow = env["CLAUDE_CONFIG_DIR"], pluginsOf(args), env["CLAUDE_SANDBOX_NET_ALLOW"]
	for _, conn := range connections {
		if env[conn.flag] == "1" {
			c.conns = append(c.conns, conn.name)
		}
	}
	return c
}

// registryEntry is the part of a claude's entry in Claude Code's registry,
// sessions/<pid>.json in its profile, that backup reads.
type registryEntry struct {
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Cwd       string `json:"cwd"`
	Kind      string `json:"kind"`
	ProcStart string `json:"procStart"`
	Spare     bool   `json:"spare"`
}

// registryClaudes reads the claudes from Claude Code's registry, in $HOME's
// profiles: ~/.claude, and ~/.claude-<n> as __claude starts them. An entry
// counts while its process is the one that wrote it, which ps says as Claude
// Code itself checks it: the process started when the entry's procStart says
// (or, an entry without one, runs a claude). A background agent's entry, or a
// spare's, is left out, as the terminal-less claudes are on Linux.
func (h host) registryClaudes() (map[int]procStat, []claudeProc, error) {
	out, err := h.ps()
	if err != nil {
		return nil, nil, fmt.Errorf("finding the open sessions runs ps: %w", err)
	}
	ps, started, commands := parsePS(out)
	entries, _ := os.ReadDir(h.home)
	var found []claudeProc
	for _, profile := range entries {
		config := filepath.Join(h.home, profile.Name())
		if _, ok := instance(h.home, config); !ok && profile.Name() != ".claude" {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(config, "sessions"))
		for _, f := range files {
			name, isJSON := strings.CutSuffix(f.Name(), ".json")
			pid, err := strconv.Atoi(name)
			if !isJSON || err != nil {
				continue
			}
			data, err := os.ReadFile(filepath.Join(config, "sessions", f.Name()))
			var e registryEntry
			if err != nil || json.Unmarshal(data, &e) != nil || e.PID != pid {
				continue
			}
			start, runs := started[pid]
			switch {
			case !runs, e.Spare, e.Kind != "" && e.Kind != "interactive":
				continue
			case e.ProcStart != "" && strings.Join(strings.Fields(e.ProcStart), " ") != start:
				continue
			case e.ProcStart == "" && !strings.Contains(commands[pid], "claude"):
				continue
			}
			c := claudeProc{
				pid: pid, id: e.SessionID, config: config, cwd: e.Cwd,
				plugins: pluginsOf(strings.Fields(commands[pid])), connsFromPane: true,
			}
			switch {
			case !uuidRE.MatchString(e.SessionID):
				c.err = errors.New("its registry entry names no session")
			case !filepath.IsAbs(e.Cwd):
				c.err = errors.New("its registry entry names no directory")
			}
			found = append(found, c)
		}
	}
	slices.SortFunc(found, func(a, b claudeProc) int { return a.pid - b.pid })
	return ps, found, nil
}

// parsePS reads psTable's lines: the process table, when each process
// started (the five words of lstart, one space apart), and its command line
// (its arguments one space apart, as ps joins them).
func parsePS(out []byte) (map[int]procStat, map[int]string, map[int]string) {
	ps, started, commands := map[int]procStat{}, map[int]string{}, map[int]string{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 7 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		ps[pid] = procStat{ppid: ppid}
		started[pid] = strings.Join(f[2:7], " ")
		commands[pid] = strings.Join(f[7:], " ")
	}
	return ps, started, commands
}

// connectionsOf is the credentials the command a tmux pane started with hands
// its claude: __claude_build_cmd opens it with a CLAUDE_SANDBOX_ALLOW_<NAME>=1
// word for each, then the network filter's extra hosts, before anything else.
// tmux quotes the command it shows (#{pane_start_command} is "…"), which
// those words never need.
func connectionsOf(start string) []string {
	given := map[string]bool{}
	for _, word := range strings.Fields(strings.TrimLeft(start, `"'`)) {
		name, value, ok := strings.Cut(word, "=")
		if !ok || !strings.HasPrefix(name, "CLAUDE_SANDBOX_") {
			break
		}
		given[name] = value == "1"
	}
	var conns []string
	for _, c := range connections {
		if given[c.flag] {
			conns = append(conns, c.name)
		}
	}
	return conns
}

// openSessions is the sessions open on this machine, in tmux's order of
// sessions and windows, then by directory, and a note for each claude whose
// session can't be saved.
func (h host) openSessions() ([]savedSession, []string, error) {
	ps, found, err := h.claudes()
	if err != nil {
		return nil, nil, err
	}
	var panes map[int]pane
	if len(found) > 0 {
		panes = h.panes()
	}
	var sessions []savedSession
	var notes []string
	for _, c := range found {
		s, err := h.describeOpen(ps, panes, c)
		if err != nil {
			notes = append(notes, err.Error())
			continue
		}
		if !slices.ContainsFunc(sessions, func(o savedSession) bool { return o.ID == s.ID }) {
			sessions = append(sessions, s)
		}
	}
	slices.SortStableFunc(sessions, func(a, b savedSession) int {
		switch {
		case (a.TmuxSession == "") != (b.TmuxSession == ""):
			if a.TmuxSession == "" {
				return 1
			}
			return -1
		case a.TmuxSession != b.TmuxSession:
			return strings.Compare(a.TmuxSession, b.TmuxSession)
		case a.TmuxWindow != b.TmuxWindow:
			return a.TmuxWindow - b.TmuxWindow
		}
		return strings.Compare(a.Cwd, b.Cwd)
	})
	return sessions, notes, nil
}

// describeOpen is the saved form of the session claude c has open, or why it
// can't be saved.
func (h host) describeOpen(ps map[int]procStat, panes map[int]pane, c claudeProc) (savedSession, error) {
	if c.cwd == "" && c.err != nil {
		return savedSession{}, fmt.Errorf("claude %d: %w", c.pid, c.err)
	}
	where := fmt.Sprintf("claude %d in %s", c.pid, tilde(h.home, c.cwd))
	if c.err != nil {
		return savedSession{}, fmt.Errorf("%s: %w", where, c.err)
	}
	if !rowSafe(c.cwd) {
		return savedSession{}, fmt.Errorf("%s: its directory's name holds a control character", where)
	}
	config := c.config
	if config == "" {
		config = filepath.Join(h.home, ".claude")
	}
	config = filepath.Clean(config)
	if _, ok := instance(h.home, config); !ok {
		return savedSession{}, fmt.Errorf("%s: its profile %s is not one __claude starts (~/.claude-<n>)", where, tilde(h.home, config))
	}
	paths, err := transcripts(config, c.id)
	if err != nil {
		return savedSession{}, fmt.Errorf("%s: session %s has no conversation to resume yet", where, c.id)
	}
	s, ok := load(paths[0], c.id)
	if !ok {
		return savedSession{}, fmt.Errorf("%s: session %s is not one /resume offers", where, c.id)
	}
	saved := savedSession{ID: c.id, Config: config, Cwd: c.cwd, Title: s.title, Connections: c.conns, Plugins: c.plugins}
	if rowSafe(c.netAllow) && c.netAllow != none {
		saved.NetAllow = c.netAllow
	}
	if p, ok := paneOf(ps, panes, c.pid); ok {
		if rowSafe(p.session) && p.session != none {
			saved.TmuxSession, saved.TmuxWindow = p.session, p.window
		}
		if c.connsFromPane {
			saved.Connections = connectionsOf(p.start)
		}
	}
	return saved, nil
}

// pluginsOf is the plugins claude's arguments load, by name: the last element
// of each --plugin-dir. A name a row can't carry is left out.
func pluginsOf(args []string) []string {
	var names []string
	for i := 1; i < len(args); i++ {
		dir, ok := strings.CutPrefix(args[i], "--plugin-dir=")
		if !ok && args[i] == "--plugin-dir" && i+1 < len(args) {
			i++
			dir, ok = args[i], true
		}
		if !ok {
			continue
		}
		if name := filepath.Base(dir); rowSafe(name) && !strings.Contains(name, ",") && name != none && !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	return names
}

// rowSafe reports whether s can be a field of a row of saved: it holds no
// control character (a tab separates the fields, a newline the rows).
func rowSafe(s string) bool {
	return !strings.ContainsFunc(s, control)
}

// instance is the number __claude starts profile config with, config being
// $HOME/.claude-<n>.
func instance(home, config string) (string, bool) {
	n, ok := strings.CutPrefix(filepath.Clean(config), filepath.Join(home, ".claude-"))
	if !ok || n == "" || strings.Trim(n, "0123456789") != "" {
		return "", false
	}
	return n, true
}

// tilde is path with $HOME written ~.
func tilde(home, path string) string {
	if rest, ok := strings.CutPrefix(path, home); ok && home != "" && (rest == "" || rest[0] == '/') {
		return "~" + rest
	}
	return path
}

// backupDir is where backup keeps its files: claude-sessions/backups in
// $XDG_STATE_HOME, else in ~/.local/state. The sandbox launcher binds neither
// writable, so no session can rewrite what restore will start.
func backupDir(home string) string {
	state := os.Getenv("XDG_STATE_HOME")
	if !filepath.IsAbs(state) {
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "claude-sessions", "backups")
}

// backupName is the file a backup made at t goes to: the names sort as the
// times do.
func backupName(t time.Time) string {
	return t.UTC().Format("20060102T150405Z") + ".json"
}

// backups is the backup files in dir, oldest first.
func backups(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		name := e.Name()
		if t, err := time.Parse("20060102T150405Z.json", name); err == nil && backupName(t) == name && e.Type().IsRegular() {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	return names, nil
}

// backup saves the sessions open on this machine to a new file in dir, says
// on out what it saved and on notes what it couldn't, and keeps the
// maxBackups newest files. With no session open it writes nothing, so the
// last backup stays the one restore offers.
func backup(out, notes io.Writer, h host, dir string, now time.Time) error {
	sessions, skipped, err := h.openSessions()
	if err != nil {
		return err
	}
	for _, n := range skipped {
		_, _ = fmt.Fprintln(notes, "claude-sessions: skipped", n)
	}
	if len(sessions) == 0 {
		_, err = fmt.Fprintln(out, "no session to back up: the last backup stays")
		return err
	}
	data, err := json.MarshalIndent(backupFile{Version: 1, Time: now, Sessions: sessions}, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, backupName(now))
	if err = writeAtomic(path, append(data, '\n')); err != nil {
		return err
	}
	if names, err := backups(dir); err == nil && len(names) > maxBackups {
		for _, name := range names[:len(names)-maxBackups] {
			_ = os.Remove(filepath.Join(dir, name))
		}
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "backed up %s to %s\n", count(len(sessions), "session"), tilde(h.home, path))
	writeRows(&b, h.home, sessions, func(savedSession) string { return "  " })
	_, err = b.WriteTo(out)
	return err
}

// writeAtomic writes data to path through a file beside it, so a reader
// never sees half of it.
func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".backup-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // fails once renamed: nothing left
	if err = writeFile(tmp, 0o600, data); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// writeRows writes one line per session: what lead makes of it, its
// directory, its profile when that is not the first, its connections, and
// its title, the columns aligned.
func writeRows(w *bytes.Buffer, home string, sessions []savedSession, lead func(savedSession) string) {
	dirs, tags := make([]string, len(sessions)), make([]string, len(sessions))
	dirWidth, tagWidth := 0, 0
	for i, s := range sessions {
		dirs[i] = tilde(home, s.Cwd)
		var t []string
		if n, _ := instance(home, s.Config); n != "1" {
			t = append(t, "profile "+n)
		}
		tags[i] = strings.Join(append(t, s.Connections...), " ")
		dirWidth = max(dirWidth, utf8.RuneCountInString(dirs[i]))
		tagWidth = max(tagWidth, utf8.RuneCountInString(tags[i]))
	}
	for i, s := range sessions {
		line := lead(s) + pad(dirs[i], dirWidth) + "  "
		if tagWidth > 0 {
			line += pad(tags[i], tagWidth) + "  "
		}
		w.WriteString(strings.TrimRight(line+s.Title, " ") + "\n")
	}
}

// saved writes the sessions of the newest backup in dir as rows for the
// restore picker, in the backup's order: the session's id, its profile's
// number, its directory, its connections, its CLAUDE_SANDBOX_NET_ALLOW, its
// plugins (the lists comma-separated) and its tmux session, each "-" when it
// has none, then its title and the line the picker shows, a tab apart. It
// says on notes which backup that is, and leaves out, with a note, a session
// that can't be resumed: one open now, which a held lock names or a running
// claude has, and one whose conversation or directory is gone.
func saved(out, notes io.Writer, h host, dir string, now time.Time) error {
	names, err := backups(dir)
	if errors.Is(err, fs.ErrNotExist) || err == nil && len(names) == 0 {
		return errors.New("no backup yet")
	}
	if err != nil {
		return err
	}
	path := filepath.Join(dir, names[len(names)-1])
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var b backupFile
	if err = json.Unmarshal(data, &b); err != nil {
		return fmt.Errorf("%s: %w", tilde(h.home, path), err)
	}
	open := openByLock(h.home, now)
	if _, found, err := h.claudes(); err != nil {
		_, _ = fmt.Fprintf(notes, "claude-sessions: %v; a session still open would be started twice\n", err)
	} else {
		for _, c := range found {
			if c.id != "" {
				open[c.id] = true
			}
		}
	}
	_, _ = fmt.Fprintf(notes, "claude-sessions: the backup of %s, %s\n", b.Time.Local().Format("Mon 2 Jan 15:04"), ago(now.Sub(b.Time)))
	var keep []savedSession
	ages := map[string]string{}
	for _, s := range b.Sessions {
		what := fmt.Sprintf("%q (%s)", s.Title, tilde(h.home, s.Cwd))
		n, ok := instance(h.home, s.Config)
		fields := s.Cwd + s.NetAllow + s.TmuxSession + s.Title + strings.Join(s.Connections, "") + strings.Join(s.Plugins, "")
		if !ok || !uuidRE.MatchString(s.ID) || !rowSafe(fields) {
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out %s: the backup can't say how to start it\n", what)
			continue
		}
		paths, err := transcripts(s.Config, s.ID)
		switch {
		case open[s.ID]:
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out %s: it is open\n", what)
			continue
		case err != nil:
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out %s: its conversation is gone from profile %s\n", what, n)
			continue
		case !isDir(s.Cwd):
			_, _ = fmt.Fprintf(notes, "claude-sessions: left out %s: its directory is gone\n", what)
			continue
		}
		ages[s.ID] = "?"
		if st, err := os.Stat(paths[0]); err == nil {
			ages[s.ID] = age(now.Sub(st.ModTime()))
		}
		keep = append(keep, s)
	}
	var shown bytes.Buffer
	writeRows(&shown, h.home, keep, func(s savedSession) string { return pad(ages[s.ID], 4) + "  " })
	lines := strings.Split(shown.String(), "\n")
	var w bytes.Buffer
	for i, s := range keep {
		n, _ := instance(h.home, s.Config)
		w.WriteString(strings.Join([]string{
			s.ID, n, s.Cwd,
			orNone(strings.Join(s.Connections, ",")), orNone(s.NetAllow), orNone(strings.Join(s.Plugins, ",")),
			orNone(s.TmuxSession), s.Title, lines[i],
		}, "\t") + "\n")
	}
	_, err = w.WriteTo(out)
	return err
}

// orNone is s, or none for an empty s.
func orNone(s string) string {
	if s == "" {
		return none
	}
	return s
}
