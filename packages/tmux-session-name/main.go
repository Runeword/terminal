// Command tmux-session-name labels a tmux session with a few words on what its
// windows are doing, which tmux.conf's status-left shows for the current
// session, after the session numbers, and names each of its windows with one
// word, which the window list shows. A local model, Qwen3.5 2B run by
// llama.cpp, names them from each pane's program, folder, git branch and
// title, never from what is on screen, and only when those change. Nothing
// leaves the machine.
//
// tmux.conf runs it in the background from the client-session-changed and
// session-window-changed hooks, and M-N runs it with -force after storing what
// was typed in @label_pin: a typed label sticks, and an empty one asks the
// model again. It keeps the label's state in session options:
//
//	@label      the label the status line shows
//	@label_pin  a label typed with M-N, which wins over the model's
//	@label_fp   the fingerprint of the panes @label was made from
//	@label_at   when the model was last asked, in Unix seconds
//	@label_err  why the last attempt failed
//
// and each window's in window options (-force only hurries the label):
//
//	@wlabel      the name the window list shows, in place of the program's
//	@wlabel_fp   the fingerprint of the window's panes @wlabel was made from
//	@wlabel_at   when the model was last asked about the window
//	@wlabel_err  why the window's last attempt failed
//
// It always exits 0 and prints nothing: run-shell shows output or a non-zero
// exit over the pane.
//
// Each label or name is one llama-completion process, so the model takes
// memory (about 2 GB) only for the few seconds it runs, one call at a time.
// The call loads a prompt cache of its system message, which the first call
// makes under the user's cache directory, and reads only the pane lines. A
// GBNF grammar holds its answer to the label's or the name's shape, and
// sanitize or word checks it again before tmux sees it.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// cooldown is the least time between two unforced model calls for a session,
// or for a window: a pane that keeps changing program asks once a minute, not
// on every switch.
const cooldown = 60 * time.Second

// modelTimeout bounds one model call.
const modelTimeout = 60 * time.Second

// stateFormat reads a session's label state in one call. The pin comes last,
// so a tab typed into it stays in it.
const stateFormat = "#{session_attached}\t#{@label}\t#{@label_fp}\t#{@label_at}\t#{@label_err}\t#{host}\t#{@label_pin}"

// paneFormat lists a session's panes for parsePanes.
const paneFormat = "#{window_id}\t#{window_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}"

// windowFormat lists a session's windows for parseWindows. The name comes
// last, so a tab in it stays in it.
const windowFormat = "#{window_id}\t#{@wlabel_fp}\t#{@wlabel_at}\t#{@wlabel_err}\t#{@wlabel}"

// llamaCompletion and modelPath are set at build time (default.nix ldflags) to
// the llama.cpp binary and the GGUF model file.
var (
	llamaCompletion = "llama-completion"
	modelPath       = ""
)

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

// windowState is a window's name state, as windowFormat reads it.
type windowState struct {
	id    string
	label string
	fp    string
	at    int64
	err   string
}

func parseWindows(out string) []windowState {
	var windows []windowState
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		f := strings.SplitN(line, "\t", 5)
		if len(f) != 5 {
			continue
		}
		at, _ := strconv.ParseInt(f[2], 10, 64)
		windows = append(windows, windowState{id: f[0], fp: f[1], at: at, err: f[3], label: f[4]})
	}
	return windows
}

// query is one question for the model: its system message, the pane lines it
// is about, the GBNF grammar that holds the answer to its shape, and the name
// of the prompt cache that holds the system message.
type query struct {
	system, lines, grammar, cache string
}

// deps are run's effects, replaced in tests.
type deps struct {
	// tmux runs one tmux command line and returns its output.
	tmux func(args ...string) (string, error)
	// ask gives the model q and returns its answer.
	ask func(q query) (string, error)
	// branch gives a directory's git branch.
	branch func(dir string) string
	// lock takes the session's lock, or reports that another run holds it.
	lock func(id string) (unlock func(), ok bool)
	now  time.Time
	home string
}

// run updates the label of session id and the names of its windows. The
// error it returns says why a label or a name could not be made; a session
// that is gone or holds no client is no error.
func run(id string, force bool, d deps) error {
	out, err := d.tmux("display-message", "-p", "-t", id, stateFormat)
	if err != nil {
		return nil // the session closed before the hook's job ran
	}
	st := parseState(out)
	if !st.attached && !force {
		return nil // only the current session's label and names are on show
	}
	// A typed label needs no model: it shows at once, even while another run
	// holds the lock.
	pin := sanitize(st.pin)
	if pin != "" {
		if err = write(d, id, st, pin, st.fp, st.at, ""); err != nil {
			return err
		}
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
	if pin == "" {
		err = labelSession(id, force, st, panes, d)
	}
	return errors.Join(err, nameWindows(id, panes, d))
}

// labelSession updates the label of session id, whose state is st, from its
// panes.
func labelSession(id string, force bool, st state, panes []pane, d deps) error {
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
	reply, err := d.ask(query{system: systemPrompt, lines: prompt(panes), grammar: labelGrammar, cache: "label"})
	label := sanitize(reply)
	if err == nil && label == "" {
		err = fmt.Errorf("no label in the answer %q", reply)
	}
	if err != nil {
		err = fmt.Errorf("model: %w", err)
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

// nameWindows names each window of session id in one word, after what its
// panes work on, when they changed since its name was made.
func nameWindows(id string, panes []pane, d deps) error {
	out, err := d.tmux("list-windows", "-t", id, "-F", windowFormat)
	if err != nil {
		return nil // the session closed meanwhile
	}
	byWindow := make(map[string][]pane)
	for _, p := range panes {
		byWindow[p.windowID] = append(byWindow[p.windowID], p)
	}
	var errs []error
	for _, w := range parseWindows(out) {
		errs = append(errs, nameWindow(w, byWindow[w.id], d))
	}
	return errors.Join(errs...)
}

// nameWindow updates the name of window w from its panes. A window whose
// panes say nothing but their folder is named after it, with no model call.
func nameWindow(w windowState, panes []pane, d deps) error {
	if len(panes) == 0 {
		return nil // opened after list-panes ran
	}
	fp := fingerprint(panes)
	if fp == w.fp {
		return nil
	}
	if plain(panes) {
		if name, ok := folderWord(panes); ok {
			return writeWindow(d, w, name, fp, w.at, "")
		}
	}
	if d.now.Sub(time.Unix(w.at, 0)) < cooldown {
		return nil
	}
	at := d.now.Unix()
	reply, err := d.ask(query{system: windowSystemPrompt, lines: windowLines(panes), grammar: wordGrammar, cache: "window"})
	name := word(reply)
	if err == nil && name == "" {
		err = fmt.Errorf("no word in the answer %q", reply)
	}
	if err != nil {
		err = fmt.Errorf("model: %w", err)
		// As for the session: keep the name and its fingerprint, and try
		// again on a change once the cooldown has passed.
		_ = writeWindow(d, w, w.label, w.fp, at, oneLine(err.Error()))
		return fmt.Errorf("window %s: %w", w.id, err)
	}
	if saysNothing(name, panes) {
		name, _ = folderWord(panes)
	}
	return writeWindow(d, w, name, fp, at, "")
}

// write sets the session's label options that differ from st.
func write(d deps, id string, st state, label, fp string, at int64, errText string) error {
	c := changes{target: []string{"-t", id}}
	c.set("@label", st.label, label)
	c.set("@label_fp", st.fp, fp)
	if at != st.at {
		c.set("@label_at", "", strconv.FormatInt(at, 10))
	}
	c.set("@label_err", st.err, errText)
	return c.apply(d)
}

// writeWindow sets the window's name options that differ from w.
func writeWindow(d deps, w windowState, label, fp string, at int64, errText string) error {
	c := changes{target: []string{"-w", "-t", w.id}}
	c.set("@wlabel", w.label, label)
	c.set("@wlabel_fp", w.fp, fp)
	if at != w.at {
		c.set("@wlabel_at", "", strconv.FormatInt(at, 10))
	}
	c.set("@wlabel_err", w.err, errText)
	return c.apply(d)
}

// changes builds one tmux command line that sets the options of a session or
// a window whose values changed: setting an option redraws every client, so
// unchanged ones are left alone.
type changes struct {
	target []string // set-option's target: -t <session>, or -w -t <window>
	args   []string
}

// set sets option name to value, or unsets it when value is empty, unless
// value is old.
func (c *changes) set(name, old, value string) {
	if value == old {
		return
	}
	if len(c.args) > 0 {
		c.args = append(c.args, ";")
	}
	c.args = append(c.args, "set-option")
	if value == "" {
		c.args = append(c.args, "-u")
		c.args = append(c.args, c.target...)
		c.args = append(c.args, name)
		return
	}
	c.args = append(c.args, c.target...)
	c.args = append(c.args, "--", name, value)
}

// apply runs the command line, if anything changed.
func (c *changes) apply(d deps) error {
	if len(c.args) == 0 {
		return nil
	}
	_, err := d.tmux(c.args...)
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

// runModel asks the local model a query: one llama-completion run of model on
// the ChatML prompt, greedy (the same panes always get the same answer), its
// answer held to the query's grammar. It starts from the prompt cache of the
// query's system message in cacheDir, so it reads only the pane lines, a few
// dozen tokens, which 4 threads read as fast as 16 for half the CPU time. It
// keeps each batch under 32 tokens: from 32 on, llama.cpp hands a batch to
// the BLAS library nixpkgs builds it with, which takes several times the CPU
// time of llama.cpp's own code for this model.
func runModel(bin, model, cacheDir string) func(query) (string, error) {
	return func(q query) (string, error) {
		if model == "" {
			return "", errors.New("no model was built in")
		}
		threads := strconv.Itoa(min(runtime.NumCPU(), 4))
		prefix := promptPrefix(q.system)
		cache := promptCache(cacheDir, q.cache, bin+"\n"+model+"\n"+prefix, func(path string) error {
			// In one batch, not in batches of 31 like the calls: a cache
			// made this way kept the names of 24 of the 26 tuning samples,
			// against 22 (measured 2026-10-28). llama-completion saves the
			// cache when it samples its first token.
			_, err := llama(bin, "-m", model, "-no-cnv", "-p", prefix, "-n", "1", "--temp", "0",
				"-c", "1024", "-t", threads, "--no-display-prompt", "--no-warmup", "--prompt-cache", path)
			return err
		})
		args := []string{
			"-m", model, "-no-cnv", "-p", chatPrompt(q.system, q.lines),
			"--grammar", q.grammar, "-n", "12", "--temp", "0",
			"-c", "1024", "-t", threads, "-ub", "31",
			"--no-display-prompt", "--no-warmup",
		}
		if cache != "" {
			args = append(args, "--prompt-cache", cache, "--prompt-cache-ro")
		}
		out, err := llama(bin, args...)
		if err != nil {
			return "", err
		}
		return answer(out), nil
	}
}

// llama runs llama-completion bin with args and returns what it printed.
// llama.cpp logs to stderr, whose last line says why a run failed.
func llama(bin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), modelTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err == nil {
		return string(out), nil
	}
	lines := strings.Split(strings.TrimSpace(stderr.String()), "\n")
	if last := strings.TrimSpace(lines[len(lines)-1]); last != "" {
		return "", fmt.Errorf("%w: %s", err, last)
	}
	return "", err
}

// cacheFile is the file name of the prompt cache called name whose content
// depends on key.
func cacheFile(name, key string) string {
	sum := sha256.Sum256([]byte(key))
	return name + "-" + hex.EncodeToString(sum[:8]) + ".cache"
}

// promptCache returns the path of the prompt cache called name in dir, made
// with build first if it isn't there. key is everything its content depends
// on (llama.cpp, the model and the system message), and its file name holds
// key's hash, so an upgrade or a new prompt makes a new cache, which replaces
// the old one. It returns "" when the cache can't be made: the call then reads
// the whole prompt.
func promptCache(dir, name, key string, build func(path string) error) string {
	if dir == "" {
		return ""
	}
	path := filepath.Join(dir, cacheFile(name, key))
	if _, err := os.Stat(path); err == nil {
		return path
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return ""
	}
	// Made under a name of its own and renamed into place: no call loads a
	// half-written cache, and two runs making it at once don't mix.
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	defer func() { _ = os.Remove(tmp) }()
	if err := build(tmp); err != nil {
		return ""
	}
	if err := os.Rename(tmp, path); err != nil {
		return ""
	}
	old, _ := filepath.Glob(filepath.Join(dir, name+"-*"))
	for _, f := range old {
		if f != path {
			_ = os.Remove(f)
		}
	}
	return path
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
	// A background job: let the model's few seconds of CPU yield to what the
	// user is doing. llama-completion inherits the niceness.
	_ = syscall.Setpriority(syscall.PRIO_PROCESS, 0, 10)
	home, _ := os.UserHomeDir()
	cacheDir := ""
	if base, err := os.UserCacheDir(); err == nil {
		cacheDir = filepath.Join(base, "tmux-session-name")
	}
	runDir := os.Getenv("XDG_RUNTIME_DIR")
	if runDir == "" {
		runDir = os.TempDir()
	}
	dir := filepath.Join(runDir, "tmux-session-name")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		dir = os.TempDir()
	}
	d := deps{
		tmux:   runTmux,
		ask:    runModel(llamaCompletion, modelPath, cacheDir),
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
