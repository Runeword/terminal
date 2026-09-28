package main

// The ga/gru/grd/gsp file picker (__git_pick_files in
// .config/shell/functions/git.bash) is one fzf showing either the changed files
// or, drilled into one file, that file's hunks. Its bindings call these
// subcommands with the picker's state directory; key and load print fzf actions.
//
// Files in the state directory that shell commands read stay plain:
//
//	.files  the files list, saved by git.bash; a return reloads it
//	.hunks  the drilled file's hunk labels; a drill reloads it
//	.diff   the drilled file's diff; the preview assembles hunk {n}+1 from it
//	.drill  the drilled path, present only while the hunks list is up
//	.query  the files list's query saved at a drill; a return restores it
//	.whole  on finalize, the selected files, one per line; .commit confirms
//
// state.json holds the rest (see pickerState).

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// pickerState is the picker's own state, rewritten by key and load.
type pickerState struct {
	// Specs maps each drilled path to its hunk selection: "ALL", or 1-based
	// hunk indices joined by spaces. A path without one is whole iff selected.
	Specs map[string]string `json:"specs,omitempty"`
	// Marks is the files list's selection when the current drill started: the
	// reload that shows the hunks wipes fzf's own marks.
	Marks []string `json:"marks,omitempty"`
	// Pending is the list switch key requested. load commits it once the
	// reloaded list is in, so a key pressed before then still acts on the list
	// on screen.
	Pending *listSwitch `json:"pending,omitempty"`
}

type listSwitch struct {
	Drill   string `json:"drill,omitempty"` // path drilled into; empty for the files list
	Actions string `json:"actions"`         // fzf actions to run before the list is painted
}

// picker runs the subcommands against state directory dir. getenv and diff
// are os.Getenv and gitDiff, faked in tests.
type picker struct {
	dir    string
	getenv func(string) string
	diff   func(staged bool, path string) (string, error)
}

func (p picker) path(name string) string { return filepath.Join(p.dir, name) }

func (p picker) loadState() (pickerState, error) {
	var st pickerState
	data, err := os.ReadFile(p.path("state.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return st, err
	}
	return st, json.Unmarshal(data, &st)
}

// saveState replaces state.json through a rename: the preview reads specs
// (hint) while keys rewrite them.
func (p picker) saveState(st pickerState) error {
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	tmp := p.path("state.json.tmp")
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p.path("state.json"))
}

// readLines returns the non-empty lines of name; a missing file has none.
func readLines(name string) ([]string, error) {
	data, err := os.ReadFile(name)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return slices.DeleteFunc(strings.Split(string(data), "\n"), func(l string) bool { return l == "" }), nil
}

// shellQuote quotes s for the sh -c that fzf runs action commands through.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// finalize ends the picker: git.bash turns .whole (and each path's spec) into
// the command it prints.
func (p picker) finalize(selected []string) error {
	var b strings.Builder
	for _, s := range selected {
		b.WriteString(s + "\n")
	}
	if err := os.WriteFile(p.path(".whole"), []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.WriteFile(p.path(".commit"), nil, 0o600)
}

// key returns the fzf actions for enter, right, left or esc, whose meaning
// depends on the list shown. selFile ({+f}) and sel ({+n}, 0-based) fall back
// to the focused item when nothing is selected, so FZF_SELECT_COUNT gates them;
// item is the focused item ({}).
//
// Switching lists is a reload-sync of the other one: it keeps the current list
// up until the new one is read. What must land with the new list (header,
// marks, cursor, query) is queued for load, which fzf runs before painting the
// reloaded list, so a switch is one frame. A query change searches again, but
// a list this small re-filters in well under a millisecond.
func (p picker) key(staged bool, key, selFile, item string, sel []int) (string, error) {
	st, err := p.loadState()
	if err != nil {
		return "", err
	}
	drilled, err := os.ReadFile(p.path(".drill"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	count, _ := strconv.Atoi(p.getenv("FZF_SELECT_COUNT"))
	if len(drilled) > 0 {
		return p.hunksKey(st, key, strings.TrimSuffix(string(drilled), "\n"), count, sel)
	}
	return p.filesKey(st, staged, key, selFile, item, count)
}

func (p picker) filesKey(st pickerState, staged bool, key, selFile, item string, count int) (string, error) {
	switch key {
	case "left":
		return "backward-char", nil
	case "esc":
		// The global esc (FZF_DEFAULT_OPTS): abort from search mode; from nav
		// mode, back to search, the toggle alt-i is bound to.
		if s := p.getenv("FZF_INPUT_STATE"); s == "" || s == "enabled" {
			return "abort", nil
		}
		return "trigger(alt-i)", nil
	case "enter", "right":
	default:
		return "", nil
	}
	if item == "" {
		return "", nil
	}
	diff, err := p.diff(staged, item)
	if err != nil {
		return "", err
	}
	var marks []string
	if count > 0 {
		if marks, err = readLines(selFile); err != nil {
			return "", err
		}
	}
	files, err := parseDiff(strings.NewReader(diff))
	if err != nil {
		return "", err
	}
	hunks := labels(files)
	if len(hunks) == 0 {
		// No hunks (untracked, unchanged, binary): Enter finalizes the selection
		// as it stands, where such a file counts only if Tab-marked; Right does
		// nothing.
		if key == "right" {
			return "", nil
		}
		return "accept", p.finalize(marks)
	}

	// Drill: save what the files list needs back, and queue the hunks list's
	// header and preselection: the saved spec, or every hunk for a Tab-marked
	// file without one, so a drill can't silently drop it.
	query := p.getenv("FZF_QUERY")
	for name, data := range map[string]string{".diff": diff, ".hunks": strings.Join(hunks, "\n") + "\n", ".query": query} {
		if err := os.WriteFile(p.path(name), []byte(data), 0o600); err != nil {
			return "", err
		}
	}
	spec := st.Specs[item]
	if spec == "" && slices.Contains(marks, item) {
		spec = "ALL"
	}
	actions := []string{"change-header(" + p.getenv("GFS_HEADER_HUNKS") + ")"}
	if query != "" {
		actions = append(actions, "change-query()", "wait")
	}
	if spec == "ALL" {
		actions = append(actions, "select-all")
	} else {
		for _, i := range strings.Fields(spec) {
			actions = append(actions, "pos("+i+")", "select")
		}
	}
	st.Marks = marks
	st.Pending = &listSwitch{Drill: item, Actions: strings.Join(append(actions, "first"), "+")}
	if err := p.saveState(st); err != nil {
		return "", err
	}
	return "reload-sync(cat " + shellQuote(p.path(".hunks")) + ")", nil
}

func (p picker) hunksKey(st pickerState, key, drilled string, count int, sel []int) (string, error) {
	switch key {
	case "right":
		return "forward-char", nil
	case "enter", "left", "esc":
	default:
		return "", nil
	}
	hunks, err := readLines(p.path(".hunks"))
	if err != nil {
		return "", err
	}
	// Record the drilled file's spec as shown: every hunk marked is ALL, a
	// subset its 1-based indices, nothing no spec.
	spec := ""
	switch {
	case count == 0:
	case count >= len(hunks):
		spec = "ALL"
	default:
		idx := slices.Clone(sel)
		slices.Sort(idx)
		parts := make([]string, len(idx))
		for i, n := range idx {
			parts[i] = strconv.Itoa(n + 1)
		}
		spec = strings.Join(parts, " ")
	}
	if st.Specs == nil {
		st.Specs = map[string]string{}
	}
	if spec == "" {
		delete(st.Specs, drilled)
	} else {
		st.Specs[drilled] = spec
	}
	// The files selected before the drill, with the drilled one in or out by
	// its spec.
	marked := slices.DeleteFunc(slices.Clone(st.Marks), func(m string) bool { return m == drilled })
	if spec != "" {
		marked = append(marked, drilled)
	}
	if key == "enter" {
		if err := p.saveState(st); err != nil {
			return "", err
		}
		return "accept", p.finalize(marked)
	}

	// Back to the files list. Marks are restored by position while the query
	// is empty (every file listed, in input order); then the saved query comes
	// back with the cursor tracking the drilled file.
	files, err := readLines(p.path(".files"))
	if err != nil {
		return "", err
	}
	actions := []string{"change-header(" + p.getenv("GFS_HEADER_FILES") + ")"}
	if p.getenv("FZF_QUERY") != "" {
		actions = append(actions, "change-query()", "wait")
	}
	at := ""
	for i, f := range files {
		pos := "pos(" + strconv.Itoa(i+1) + ")"
		if slices.Contains(marked, f) {
			actions = append(actions, pos, "select")
		}
		if f == drilled {
			at = pos
		}
	}
	if at != "" {
		actions = append(actions, at)
	}
	if q, _ := os.ReadFile(p.path(".query")); len(q) > 0 {
		restore := "transform-query(cat " + shellQuote(p.path(".query")) + ")"
		actions = append(actions, "track-current", restore, "wait", "untrack-current")
	}
	st.Pending = &listSwitch{Actions: strings.Join(actions, "+")}
	if err := p.saveState(st); err != nil {
		return "", err
	}
	return "reload-sync(cat " + shellQuote(p.path(".files")) + ")", nil
}

// load commits the switch key requested and returns the actions it queued.
// fzf runs it on every load event, once a reload has read the whole list, and
// paints that list only after these actions ran.
func (p picker) load() (string, error) {
	st, err := p.loadState()
	if err != nil || st.Pending == nil {
		return "", err
	}
	sw := st.Pending
	if sw.Drill != "" {
		err = os.WriteFile(p.path(".drill"), []byte(sw.Drill+"\n"), 0o600)
	} else if err = os.Remove(p.path(".drill")); errors.Is(err, fs.ErrNotExist) {
		err = nil
	}
	if err != nil {
		return "", err
	}
	st.Pending = nil
	return sw.Actions, p.saveState(st)
}

// gitDiff is the drilled file's zero-context diff: the index's changes
// (staged, for unstage) or the working tree's.
func gitDiff(staged bool, path string) (string, error) {
	args := []string{"diff", "--unified=0", "--", path}
	if staged {
		args = []string{"diff", "--cached", "--unified=0", "--", path}
	}
	cmd := exec.Command("git", args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return string(out), err
}

// runPicker dispatches key, load, get and hint; args start with the state
// directory.
func runPicker(cmd string, args []string, w io.Writer) error {
	if len(args) < 1 {
		return errors.New("missing state directory")
	}
	p := picker{dir: args[0], getenv: os.Getenv, diff: gitDiff}
	var out string
	var err error
	switch cmd {
	case "key":
		// DIFF-MODE KEY SELFILE ITEM [N...]
		if len(args) < 5 {
			return errors.New("usage: key SD DIFF-MODE KEY SELFILE ITEM [N...]")
		}
		sel := make([]int, 0, len(args)-5)
		for _, a := range args[5:] {
			n, err := strconv.Atoi(a)
			if err != nil {
				return fmt.Errorf("invalid index %q", a)
			}
			sel = append(sel, n)
		}
		out, err = p.key(args[1] == "staged", args[2], args[3], args[4], sel)
	case "load":
		out, err = p.load()
	case "get", "hint":
		if len(args) != 2 {
			return fmt.Errorf("usage: %s SD PATH", cmd)
		}
		var st pickerState
		st, err = p.loadState()
		spec := st.Specs[args[1]]
		switch {
		case cmd == "get" && spec != "":
			out = spec + "\n"
		case cmd == "hint" && spec != "" && spec != "ALL":
			// Whole files need no hint: fzf's own marker shows them.
			out = "◐ hunks: " + spec + "\n"
		}
	}
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, out)
	return err
}
