// Command tmux-session-name labels a tmux session with a few words on what its
// windows are doing, which tmux.conf's status-right shows for the current
// session. Claude Haiku names it from each pane's program, folder, git branch
// and title, never from what is on screen, and only when those change.
//
// tmux.conf runs it in the background from the client-session-changed and
// session-window-changed hooks, and M-N runs it with -force after storing what
// was typed in @label_pin: a typed label sticks, and an empty one asks the
// model again. It keeps its state in session options:
//
//	@label      the label status-right shows
//	@label_pin  a label typed with M-N, which wins over the model's
//	@label_fp   the fingerprint of the panes @label was made from
//	@label_at   when the model was last asked, in Unix seconds
//	@label_err  why the last attempt failed
//
// It always exits 0 and prints nothing: run-shell shows output or a non-zero
// exit over the pane.
//
// Claude runs headless and outside claude-sandbox (__claude would open a
// window, and the sandbox refuses $HOME, the usual cwd of a run-shell job):
// --safe-mode loads no hooks, plugins, MCP servers or CLAUDE.md, --tools ""
// leaves the model nothing to run, and its answer is sanitized to [a-z0-9-]
// before tmux sees it.
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// cooldown is the least time between two unforced model calls for a session:
// a pane that keeps changing program asks once a minute, not on every switch.
const cooldown = 60 * time.Second

// claudeTimeout bounds one model call.
const claudeTimeout = 60 * time.Second

// stateFormat reads a session's label state in one call. The pin comes last,
// so a tab typed into it stays in it.
const stateFormat = "#{session_attached}\t#{@label}\t#{@label_fp}\t#{@label_at}\t#{@label_err}\t#{host}\t#{@label_pin}"

// paneFormat lists a session's panes for parsePanes.
const paneFormat = "#{window_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}"

// claudeArgs ask Claude Code for one answer with no tools, customizations or
// saved session (so the cs/cf pickers never list it).
var claudeArgs = []string{
	"-p", "--safe-mode", "--model", "haiku", "--effort", "low",
	"--tools", "", "--strict-mcp-config", "--no-session-persistence",
	"--system-prompt", systemPrompt,
}

// sessionID matches a tmux session id, the only target this accepts.
var sessionID = regexp.MustCompile(`^\$[0-9]+$`)

// state is a session's label state, as stateFormat reads it.
type state struct {
	attached bool
	label    string
	fp       string
	at       int64
	err      string
	host     string
	pin      string
}

func parseState(out string) state {
	f := strings.SplitN(strings.TrimSuffix(out, "\n"), "\t", 7)
	for len(f) < 7 {
		f = append(f, "")
	}
	clients, _ := strconv.Atoi(f[0])
	at, _ := strconv.ParseInt(f[3], 10, 64)
	return state{
		attached: clients > 0,
		label:    f[1],
		fp:       f[2],
		at:       at,
		err:      f[4],
		host:     f[5],
		pin:      f[6],
	}
}

// deps are run's effects, replaced in tests.
type deps struct {
	// tmux runs one tmux command line and returns its output.
	tmux func(args ...string) (string, error)
	// claude asks the model about the panes in prompt and returns its answer.
	claude func(prompt string) (string, error)
	// branch gives a directory's git branch.
	branch func(dir string) string
	// lock takes the session's lock, or reports that another run holds it.
	lock func(id string) (unlock func(), ok bool)
	now  time.Time
	home string
}

// run updates the label of session id. The error it returns says why a label
// could not be made; a session that is gone or holds no client is no error.
func run(id string, force bool, d deps) error {
	out, err := d.tmux("display-message", "-p", "-t", id, stateFormat)
	if err != nil {
		return nil // the session closed before the hook's job ran
	}
	st := parseState(out)
	if !st.attached && !force {
		return nil // only the current session's label is on show
	}
	if pin := sanitize(st.pin); pin != "" {
		return write(d, id, st, pin, st.fp, st.at, "")
	}
	unlock, ok := d.lock(id)
	if !ok {
		return nil
	}
	defer unlock()
	out, err = d.tmux("list-panes", "-s", "-t", id, "-F", paneFormat)
	if err != nil {
		return nil
	}
	panes := parsePanes(out, d.home, st.host, d.branch)
	fp := fingerprint(panes)
	if !force && fp == st.fp && st.label != "" {
		return nil
	}
	if label, ok := idleLabel(panes); ok {
		return write(d, id, st, label, fp, st.at, "")
	}
	if !force && d.now.Sub(time.Unix(st.at, 0)) < cooldown {
		return nil
	}
	at := d.now.Unix()
	answer, err := d.claude(prompt(panes))
	label := sanitize(answer)
	if err == nil && label == "" {
		err = fmt.Errorf("no label in the answer %q", answer)
	}
	if err != nil {
		err = fmt.Errorf("claude: %w", err)
		// Keep the label and its fingerprint: the next change tries again,
		// once the cooldown from @label_at has passed.
		_ = write(d, id, st, st.label, st.fp, at, oneLine(err.Error()))
		return err
	}
	// A label typed with M-N while the model was thinking wins.
	pin, err := d.tmux("display-message", "-p", "-t", id, "#{@label_pin}")
	if err != nil || sanitize(pin) != "" {
		return nil
	}
	return write(d, id, st, label, fp, at, "")
}

// write sets the label options that differ from st in one tmux call: setting
// an option redraws every client, so unchanged ones are left alone.
func write(d deps, id string, st state, label, fp string, at int64, errText string) error {
	var args []string
	set := func(name, old, value string) {
		if value == old {
			return
		}
		if len(args) > 0 {
			args = append(args, ";")
		}
		if value == "" {
			args = append(args, "set-option", "-u", "-t", id, name)
			return
		}
		args = append(args, "set-option", "-t", id, "--", name, value)
	}
	set("@label", st.label, label)
	set("@label_fp", st.fp, fp)
	if at != st.at {
		set("@label_at", "", strconv.FormatInt(at, 10))
	}
	set("@label_err", st.err, errText)
	if len(args) == 0 {
		return nil
	}
	_, err := d.tmux(args...)
	return err
}

// oneLine fits a message into one option value: one line, at most 200 bytes,
// no tab (stateFormat's separator), and no ";", which tmux reads as the end of
// a command when it ends an argument.
func oneLine(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	if len(s) > 200 {
		s = s[:200]
	}
	return strings.NewReplacer("\t", " ", ";", ",").Replace(s)
}

func runTmux(args ...string) (string, error) {
	out, err := exec.Command("tmux", args...).Output()
	return string(out), err
}

// runClaude asks Claude Code for the label, in dir, as the first profile
// __claude runs (~/.claude-1) unless CLAUDE_CONFIG_DIR names another.
func runClaude(dir, home string) func(string) (string, error) {
	return func(prompt string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), claudeTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, "claude", claudeArgs...)
		cmd.Dir = dir
		cmd.Stdin = strings.NewReader(prompt)
		cmd.Env = os.Environ()
		if os.Getenv("CLAUDE_CONFIG_DIR") == "" {
			cmd.Env = append(cmd.Env, "CLAUDE_CONFIG_DIR="+filepath.Join(home, ".claude-1"))
		}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			if msg := strings.TrimSpace(stderr.String()); msg != "" {
				return "", fmt.Errorf("%w: %s", err, msg)
			}
			return "", err
		}
		return string(out), nil
	}
}

// lockSession takes an exclusive, non-blocking flock on the session's lock
// file in dir, so two hooks firing together ask the model once. Failing to
// make the file runs unlocked rather than not at all.
func lockSession(dir string) func(string) (func(), bool) {
	return func(id string) (func(), bool) {
		f, err := os.OpenFile(filepath.Join(dir, strings.TrimPrefix(id, "$")+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return func() {}, true
		}
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			_ = f.Close()
			return func() {}, !errors.Is(err, syscall.EWOULDBLOCK)
		}
		return func() { _ = f.Close() }, true
	}
}

func main() {
	force := flag.Bool("force", false, "ask the model even when nothing changed, the wait since the last call is short, or no client shows the session")
	flag.Parse()
	id := flag.Arg(0)
	if flag.NArg() != 1 || !sessionID.MatchString(id) {
		return
	}
	home, _ := os.UserHomeDir()
	runDir := os.Getenv("XDG_RUNTIME_DIR")
	if runDir == "" {
		runDir = os.TempDir()
	}
	// The lock files' folder is also claude's cwd: empty, so it holds no
	// project settings or CLAUDE.md.
	dir := filepath.Join(runDir, "tmux-session-name")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		dir = os.TempDir()
	}
	d := deps{
		tmux:   runTmux,
		claude: runClaude(dir, home),
		branch: gitBranch,
		lock:   lockSession(dir),
		now:    time.Now(),
		home:   home,
	}
	if err := run(id, *force, d); err != nil && *force {
		// display-message expands formats: double each # so the message
		// can't run a #(command).
		_, _ = runTmux("display-message", "-t", id, "--", "label: "+strings.ReplaceAll(oneLine(err.Error()), "#", "##"))
	}
}
