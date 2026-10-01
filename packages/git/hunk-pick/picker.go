package main

// The ga/gru/grd/gsp file picker (__git_pick_files in
// .config/shell/functions/git.bash) is one fzf showing either the changed files
// or, drilled into one file, that file's hunks. Its op (stage, unstage, discard
// or stash) decides what is listed, drilled and printed (pickOps). files lists
// the op's files, the bindings call key and load, which print fzf actions, the
// preview calls hint, and finalize prints the command for what was picked.
// Lists are NUL-separated (fzf --read0 --print0), so a path git would quote
// (non-ASCII, or holding a tab or newline) reaches every command verbatim.
//
// Files in the state directory that shell commands read stay plain:
//
//	.files  the files list, written by files; a return reloads it
//	.hunks  the drilled file's hunk labels; a drill reloads it
//	.diff   the drilled file's diff; the preview assembles hunk {n}+1 from it
//	.drill  the drilled path, present only while the hunks list is up
//	.query  the files list's query saved at a drill; a return restores it
//
// state.json holds the rest (see pickerState).

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
	"slices"
	"strconv"
	"strings"
)

// pickOp is what one op of the picker lists, drills and prints.
type pickOp struct {
	staged    bool   // list and drill the index's changes, not the worktree's
	untracked bool   // list untracked files too
	stash     bool   // print one git-stash-hunks for whole files and hunks alike
	whole     string // the whole-file command, after the git prefix
	apply     string // applies a hunk subset's patch, after the git prefix
}

var pickOps = map[string]pickOp{
	"stage":   {untracked: true, whole: "add --", apply: "apply --cached --unidiff-zero --recount"},
	"unstage": {staged: true, whole: "restore --staged --", apply: "apply --cached --reverse --unidiff-zero --recount"},
	"discard": {whole: "restore --", apply: "apply --reverse --unidiff-zero --recount"},
	"stash":   {untracked: true, stash: true},
}

// diff is the git diff a drill shows, and the printed command re-reads, for a
// file: zero-context, of the index (staged) or the worktree.
func (o pickOp) diff() []string {
	if o.staged {
		return []string{"diff", "--cached", "--unified=0"}
	}
	return []string{"diff", "--unified=0"}
}

// pickerState is the picker's own state, rewritten by key and load.
type pickerState struct {
	// Specs maps each drilled path to its hunk selection: "ALL", or 1-based
	// hunk indices joined by spaces. A path without one is whole iff selected.
	Specs map[string]string `json:"specs,omitempty"`
	// Sums maps each path whose spec is a subset to the digest of that
	// subset's patch as the hunks list showed it (patchSum), which the printed
	// command checks before applying it.
	Sums map[string]string `json:"sums,omitempty"`
	// Marks is the files list's selection when the current drill started: the
	// reload that shows the hunks wipes fzf's own marks.
	Marks []string `json:"marks,omitempty"`
	// Pending is the list switch key requested. load commits it once the
	// reloaded list is in, so a key pressed before then still acts on the list
	// on screen.
	Pending *listSwitch `json:"pending,omitempty"`
	// Accepted is the selection the picker ended with, for finalize: empty
	// when nothing was selected or the picker was cancelled.
	Accepted []string `json:"accepted,omitempty"`
}

type listSwitch struct {
	Drill   string `json:"drill,omitempty"` // path drilled into; empty for the files list
	Actions string `json:"actions"`         // fzf actions to run before the list is painted
}

// picker runs the subcommands against state directory dir. getenv and git are
// os.Getenv and runGit, faked in tests.
type picker struct {
	dir    string
	getenv func(string) string
	git    func(args ...string) (string, error)
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

// splitList returns the entries of a NUL-separated list.
func splitList(s string) []string {
	return slices.DeleteFunc(strings.Split(s, "\x00"), func(e string) bool { return e == "" })
}

// joinList is the NUL-terminated list fzf --read0 reads.
func joinList(items []string) string {
	var b strings.Builder
	for _, s := range items {
		b.WriteString(s + "\x00")
	}
	return b.String()
}

// readList returns the entries of the NUL-separated list in name (the
// picker's lists, and fzf's {+f} under --print0); a missing file has none.
func readList(name string) ([]string, error) {
	data, err := os.ReadFile(name)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return splitList(string(data)), nil
}

// shellQuote quotes s for a shell: the sh -c that fzf runs action commands
// through, and the shell that runs the printed command.
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// files lists op's changed files, relative to the repo root, sorted and
// without duplicates, and saves the list for a return to reload.
func (p picker) files(op pickOp) (string, error) {
	cmds := [][]string{{"diff", "--name-only", "-z"}}
	if op.staged {
		cmds[0] = []string{"diff", "--cached", "--name-only", "-z"}
	}
	if op.untracked {
		cmds = append(cmds, []string{"ls-files", "--others", "--exclude-standard", "-z"})
	}
	var names []string
	for _, args := range cmds {
		out, err := p.git(args...)
		if err != nil {
			return "", err
		}
		names = append(names, splitList(out)...)
	}
	slices.Sort(names)
	list := joinList(slices.Compact(names))
	return list, os.WriteFile(p.path(".files"), []byte(list), 0o600)
}

// accept ends the picker with selected as the pick.
func (p picker) accept(st pickerState, selected []string) (string, error) {
	st.Accepted = selected
	return "accept", p.saveState(st)
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
func (p picker) key(op pickOp, key, selFile, item string, sel []int) (string, error) {
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
	return p.filesKey(st, op, key, selFile, item, count)
}

func (p picker) filesKey(st pickerState, op pickOp, key, selFile, item string, count int) (string, error) {
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
	diff, err := p.git(append(op.diff(), "--", item)...)
	if err != nil {
		return "", err
	}
	var marks []string
	if count > 0 {
		if marks, err = readList(selFile); err != nil {
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
		return p.accept(st, marks)
	}

	// Drill: save what the files list needs back, and queue the hunks list's
	// header and preselection: the saved spec, or every hunk for a Tab-marked
	// file without one, so a drill can't silently drop it.
	query := p.getenv("FZF_QUERY")
	for name, data := range map[string]string{".diff": diff, ".hunks": joinList(hunks), ".query": query} {
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
	hunks, err := readList(p.path(".hunks"))
	if err != nil {
		return "", err
	}
	// Record the drilled file's spec as shown: every hunk marked is ALL, a
	// subset its 1-based indices (with the digest of their patch), nothing no
	// spec.
	spec, sum := "", ""
	switch {
	case count == 0:
	case count >= len(hunks):
		spec = "ALL"
	default:
		idx := make([]int, len(sel))
		for i, n := range sel {
			idx[i] = n + 1
		}
		slices.Sort(idx)
		parts := make([]string, len(idx))
		for i, n := range idx {
			parts[i] = strconv.Itoa(n)
		}
		spec = strings.Join(parts, " ")
		if sum, err = p.sum(idx); err != nil {
			return "", err
		}
	}
	record(&st.Specs, drilled, spec)
	record(&st.Sums, drilled, sum)
	// The files selected before the drill, with the drilled one in or out by
	// its spec.
	marked := slices.DeleteFunc(slices.Clone(st.Marks), func(m string) bool { return m == drilled })
	if spec != "" {
		marked = append(marked, drilled)
	}
	if key == "enter" {
		return p.accept(st, marked)
	}

	// Back to the files list. Marks are restored by position while the query
	// is empty (every file listed, in input order); then the saved query comes
	// back with the cursor tracking the drilled file.
	files, err := readList(p.path(".files"))
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

// record sets path's entry in *m to v, or drops it when v is empty.
func record(m *map[string]string, path, v string) {
	if v == "" {
		delete(*m, path)
		return
	}
	if *m == nil {
		*m = map[string]string{}
	}
	(*m)[path] = v
}

// sum is the digest of the patch of the drilled file's hunks at the 1-based
// indices, from the diff the hunks list shows.
func (p picker) sum(indices []int) (string, error) {
	data, err := os.ReadFile(p.path(".diff"))
	if err != nil {
		return "", err
	}
	files, err := parseDiff(bytes.NewReader(data))
	if err != nil {
		return "", err
	}
	var b bytes.Buffer
	if err := assemble(&b, files, indices); err != nil {
		return "", err
	}
	return patchSum(b.Bytes()), nil
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

// finalize returns the command for the accepted selection, git being the
// shell-quoted git prefix it runs with: the whole files (no spec, or ALL) in
// one whole-file command, then a clause per hunk subset that re-reads the
// file's diff and applies the picked hunks only if they still match their
// digest; one that changed applies nothing and fails, ending the && chain. For
// stash every clause and whole file feeds one git-stash-hunks, and a refused
// clause leaves just its own hunks unstashed. Nothing selected: no command.
func (p picker) finalize(op pickOp, git string) (string, error) {
	st, err := p.loadState()
	if err != nil {
		return "", err
	}
	var whole, picks []string
	for _, path := range st.Accepted {
		spec := st.Specs[path]
		if spec == "" || spec == "ALL" {
			whole = append(whole, shellQuote(path))
			continue
		}
		sum := st.Sums[path]
		if sum == "" {
			return "", fmt.Errorf("no digest recorded for %q's hunks", path)
		}
		picks = append(picks, git+" "+strings.Join(op.diff(), " ")+" -- "+shellQuote(path)+
			" | git-hunk-pick assemble --sum "+sum+" "+spec)
	}
	if op.stash {
		var flags strings.Builder
		for _, w := range whole {
			flags.WriteString(" --whole " + w)
		}
		switch {
		case len(picks) > 0:
			return "{ " + strings.Join(picks, "; ") + "; } | git-stash-hunks" + flags.String(), nil
		case len(whole) > 0:
			return "git-stash-hunks" + flags.String() + " </dev/null", nil
		}
		return "", nil
	}
	var parts []string
	if len(whole) > 0 {
		parts = append(parts, git+" "+op.whole+" "+strings.Join(whole, " "))
	}
	for _, c := range picks {
		parts = append(parts, c+" | "+git+" "+op.apply)
	}
	return strings.Join(parts, " && "), nil
}

// runGit runs git in the current directory, the repo root git.bash runs the
// picker from, and returns its output.
func runGit(args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return string(out), err
}

// runPicker dispatches files, key, load, hint and finalize; args start with
// the state directory.
func runPicker(cmd string, args []string, w io.Writer) error {
	usage := map[string]string{
		"files":    "SD OP",
		"key":      "SD OP KEY SELFILE ITEM [N...]",
		"load":     "SD",
		"hint":     "SD PATH",
		"finalize": "SD OP GIT",
	}[cmd]
	fixed := strings.Fields(strings.TrimSuffix(usage, " [N...]"))
	if len(args) < len(fixed) || len(args) > len(fixed) && cmd != "key" {
		return fmt.Errorf("usage: git-hunk-pick %s %s", cmd, usage)
	}
	p := picker{dir: args[0], getenv: os.Getenv, git: runGit}
	var op pickOp
	if slices.Contains(fixed, "OP") {
		var ok bool
		if op, ok = pickOps[args[1]]; !ok {
			return fmt.Errorf("unknown op %q: stage, unstage, discard or stash", args[1])
		}
	}
	var out string
	var err error
	switch cmd {
	case "files":
		out, err = p.files(op)
	case "key":
		sel := make([]int, 0, len(args)-5)
		for _, a := range args[5:] {
			n, err := strconv.Atoi(a)
			if err != nil {
				return fmt.Errorf("invalid index %q", a)
			}
			sel = append(sel, n)
		}
		out, err = p.key(op, args[2], args[3], args[4], sel)
	case "load":
		out, err = p.load()
	case "hint":
		var st pickerState
		st, err = p.loadState()
		// Whole files need no hint: fzf's own marker shows them.
		if spec := st.Specs[args[1]]; spec != "" && spec != "ALL" {
			out = "◐ hunks: " + spec + "\n"
		}
	case "finalize":
		if out, err = p.finalize(op, args[2]); out != "" {
			out += "\n"
		}
	}
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, out)
	return err
}
