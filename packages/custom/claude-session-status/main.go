// Command claude-session-status powers a live tmux dashboard of every running
// Claude Code session on the machine. There is no API to enumerate running
// sessions from outside, so each session publishes its own state via hooks:
//
//	claude-session-status hook     read hook JSON on stdin, write a state file
//	claude-session-status render   print one line per live session (one-shot)
//	claude-session-status watch    clear+render on a ticker (run in a tmux pane)
//
// State lives in one small JSON file per session, keyed by session_id, under
// $XDG_RUNTIME_DIR/claude-sessions (else ~/.claude/session-status). Sessions
// that crash or exit are pruned by PID liveness, so no "session ended" event is
// required. The hook half never writes to stdout (some hook events inject hook
// stdout into the model's context) and always exits 0 (never blocks a session).
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// State is the per-session record persisted to <dir>/<session_id>.json.
type State struct {
	SessionID string `json:"session_id"`
	PID       int    `json:"pid"` // the claude process PID, for liveness
	Cwd       string `json:"cwd"`
	Model     string `json:"model"`
	State     string `json:"state"` // waiting | tool | busy | started | idle
	Detail    string `json:"detail"`
	Updated   int64  `json:"updated"` // unix seconds
}

func stateDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "claude-sessions")
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".claude", "session-status")
	}
	return filepath.Join(os.TempDir(), "claude-sessions")
}

func sanitize(id string) string {
	id = strings.ReplaceAll(id, "/", "_")
	id = strings.ReplaceAll(id, "..", "_")
	return id
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: claude-session-status hook|render|watch [interval]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "hook":
		runHook()
	case "render":
		runRender(os.Stdout)
	case "watch":
		runWatch(os.Args[2:])
	default:
		fmt.Fprintln(os.Stderr, "unknown subcommand:", os.Args[1])
		os.Exit(2)
	}
}

// ---------------------------------------------------------------- hook (writer)

type hookInput struct {
	HookEventName string          `json:"hook_event_name"`
	SessionID     string          `json:"session_id"`
	Cwd           string          `json:"cwd"`
	Model         json.RawMessage `json:"model"` // SessionStart: {display_name,id}; often absent
	ToolName      string          `json:"tool_name"`
	ToolInput     struct {
		Command  string `json:"command"`
		FilePath string `json:"file_path"`
	} `json:"tool_input"`
	Message string `json:"message"`
}

// runHook updates one session's state file. It is deliberately silent on stdout
// and always returns 0 — a hook must never block or talk back to the session.
func runHook() {
	var in hookInput
	_ = json.NewDecoder(os.Stdin).Decode(&in) // best-effort; ignore parse errors
	if in.SessionID == "" {
		return
	}

	dir := stateDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	path := filepath.Join(dir, sanitize(in.SessionID)+".json")

	if in.HookEventName == "SessionEnd" {
		_ = os.Remove(path) // proactive cleanup if the event exists; liveness covers it otherwise
		return
	}

	// Merge with any existing record so sticky fields (e.g. model, only sent on
	// SessionStart) survive later events that omit them.
	var st State
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &st)
	}
	st.SessionID = in.SessionID
	if in.Cwd != "" {
		st.Cwd = in.Cwd
	}
	if m := parseModel(in.Model); m != "" {
		st.Model = m
	}
	st.PID = sessionPID(os.Getppid())
	st.Updated = time.Now().Unix()

	switch in.HookEventName {
	case "SessionStart":
		st.State, st.Detail = "started", ""
	case "UserPromptSubmit":
		st.State, st.Detail = "busy", "thinking…"
	case "PreToolUse":
		st.State, st.Detail = "tool", toolDetail(in)
	case "PostToolUse":
		st.State, st.Detail = "busy", "working…"
	case "Notification":
		st.State, st.Detail = "waiting", "needs input"
	case "Stop":
		st.State, st.Detail = "idle", ""
	default:
		// unknown event: just refresh pid/timestamp above
	}

	writeAtomic(path, st)
}

func parseModel(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var obj struct {
		DisplayName string `json:"display_name"`
		ID          string `json:"id"`
	}
	if json.Unmarshal(raw, &obj) == nil {
		if obj.DisplayName != "" {
			return obj.DisplayName
		}
		if obj.ID != "" {
			return obj.ID
		}
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return ""
}

func toolDetail(in hookInput) string {
	switch in.ToolName {
	case "Bash":
		c := firstLine(strings.TrimSpace(in.ToolInput.Command))
		if c != "" {
			return "Bash: " + truncate(c, 22)
		}
	case "Edit", "Write", "Read", "NotebookEdit":
		if in.ToolInput.FilePath != "" {
			return in.ToolName + ": " + truncate(filepath.Base(in.ToolInput.FilePath), 18)
		}
	}
	if in.ToolName != "" {
		return in.ToolName
	}
	return "tool"
}

func writeAtomic(path string, st State) {
	b, err := json.Marshal(st)
	if err != nil {
		return
	}
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
	}
}

// ---------------------------------------------------------------- render

const staleSecs = 12 * 3600 // backstop for the rare unresolved-PID case

func runRender(w *os.File) {
	dir := stateDir()
	now := time.Now().Unix()

	entries, _ := os.ReadDir(dir)
	var live []State
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		full := filepath.Join(dir, e.Name())
		b, err := os.ReadFile(full)
		if err != nil {
			continue
		}
		var st State
		if json.Unmarshal(b, &st) != nil {
			continue
		}
		if !alive(st.PID) || now-st.Updated > staleSecs {
			_ = os.Remove(full) // prune dead/stale sessions
			continue
		}
		live = append(live, st)
	}

	sort.SliceStable(live, func(i, j int) bool {
		if ri, rj := rank(live[i].State), rank(live[j].State); ri != rj {
			return ri < rj
		}
		return live[i].Updated > live[j].Updated
	})

	if len(live) == 0 {
		fmt.Fprintln(w, dim+"no active claude sessions"+reset)
		return
	}
	for _, st := range live {
		fmt.Fprintln(w, formatLine(st, now))
	}
}

func rank(state string) int {
	switch state {
	case "waiting":
		return 0
	case "tool", "busy", "started":
		return 1
	default: // idle and anything else
		return 2
	}
}

// alive reports whether pid is a running process. EPERM means it exists but is
// owned by another user (shouldn't happen for our own sessions) — treat as alive.
func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// ---------------------------------------------------------------- watch

func runWatch(args []string) {
	interval := time.Second
	if len(args) > 0 {
		if n, err := strconv.Atoi(args[0]); err == nil && n > 0 {
			interval = time.Duration(n) * time.Second
		}
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		fmt.Print("\x1b[H\x1b[2J") // home + clear
		fmt.Println(bold + "claude sessions" + reset)
		runRender(os.Stdout)
		<-t.C
	}
}

// ---------------------------------------------------------------- formatting

const (
	reset  = "\x1b[0m"
	bold   = "\x1b[1m"
	dim    = "\x1b[2m"
	red    = "\x1b[1;31m"
	green  = "\x1b[32m"
	yellow = "\x1b[33m"
)

func glyphColor(state string) (string, string) {
	switch state {
	case "waiting":
		return "⚠", red
	case "idle":
		return "○", dim
	case "started":
		return "●", yellow
	default: // tool, busy
		return "●", green
	}
}

func stateText(state string) string {
	switch state {
	case "waiting":
		return "needs input"
	case "idle":
		return "idle"
	case "started":
		return "starting…"
	case "busy":
		return "working…"
	default:
		return state
	}
}

func formatLine(st State, now int64) string {
	glyph, color := glyphColor(st.State)
	proj := filepath.Base(st.Cwd)
	if proj == "" || proj == "." || proj == "/" {
		proj = "?"
	}
	model := st.Model
	if model == "" {
		model = "?"
	}
	text := st.Detail
	if text == "" {
		text = stateText(st.State)
	}
	age := formatAge(now - st.Updated)
	return fmt.Sprintf("%s%s %-14s%s %s%-7s%s %-22s %s%4s%s",
		color, glyph, truncate(proj, 14), reset,
		dim, truncate(model, 7), reset,
		truncate(text, 22),
		dim, age, reset)
}

func formatAge(secs int64) string {
	switch {
	case secs < 0:
		return "now"
	case secs < 5:
		return "now"
	case secs < 60:
		return fmt.Sprintf("%ds", secs)
	case secs < 3600:
		return fmt.Sprintf("%dm", secs/60)
	case secs < 86400:
		return fmt.Sprintf("%dh", secs/3600)
	default:
		return fmt.Sprintf("%dd", secs/86400)
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// truncate shortens s to at most n runes, appending "…" when it cuts.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}

// ---------------------------------------------------------------- PID liveness

// sessionPID climbs the process tree from start (the hook's parent — usually
// the shell Claude spawned the hook in) to the claude process, so we record a
// PID that lives exactly as long as the session. It returns the first ancestor
// whose argv[0] basename contains "claude" (Claude's launcher uses exec -a
// "claude"). Falls back to the parent of `start`, then `start` itself.
func sessionPID(start int) int {
	if start <= 1 {
		return start
	}
	var parent func(int) (int, bool)
	var argv0 func(int) string
	if runtime.GOOS == "linux" {
		parent, argv0 = procParentLinux, procArgv0Linux
	} else {
		snap := psSnapshot() // one /bin/ps call, walked in-memory
		parent = func(pid int) (int, bool) { e, ok := snap[pid]; return e.ppid, ok }
		argv0 = func(pid int) string { return snap[pid].argv0 }
	}

	pid := start
	fallback := start
	for i := 0; i < 24 && pid > 1; i++ {
		if strings.Contains(strings.ToLower(argv0(pid)), "claude") {
			return pid
		}
		pp, ok := parent(pid)
		if i == 0 && ok && pp > 1 {
			fallback = pp // parent of the (transient) hook shell — best guess
		}
		if !ok || pp <= 1 || pp == pid {
			break
		}
		pid = pp
	}
	return fallback
}

func procParentLinux(pid int) (int, bool) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return 0, false
	}
	// Format: "pid (comm) state ppid ...". comm may contain spaces/parens, so
	// parse from the last ')'.
	s := string(b)
	r := strings.LastIndexByte(s, ')')
	if r < 0 {
		return 0, false
	}
	fields := strings.Fields(s[r+1:])
	if len(fields) < 2 {
		return 0, false
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, false
	}
	return ppid, true
}

func procArgv0Linux(pid int) string {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err == nil && len(b) > 0 {
		if i := bytes.IndexByte(b, 0); i >= 0 {
			b = b[:i]
		}
		return filepath.Base(string(b))
	}
	c, _ := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	return strings.TrimSpace(string(c))
}

type procEntry struct {
	ppid  int
	argv0 string
}

// psSnapshot reads the whole process table once via /bin/ps (macOS/BSD, where
// there is no /proc). The path is hardcoded so it doesn't depend on $PATH.
func psSnapshot() map[int]procEntry {
	m := map[int]procEntry{}
	out, err := exec.Command("/bin/ps", "-axo", "pid=,ppid=,command=").Output()
	if err != nil {
		return m
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		fields := strings.Fields(strings.TrimSpace(sc.Text()))
		if len(fields) < 3 {
			continue
		}
		pid, e1 := strconv.Atoi(fields[0])
		ppid, e2 := strconv.Atoi(fields[1])
		if e1 != nil || e2 != nil {
			continue
		}
		m[pid] = procEntry{ppid: ppid, argv0: filepath.Base(fields[2])}
	}
	return m
}
