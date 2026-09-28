// Command leader-aliases renders the leader-key table
// (sources/.config/shell/leader.toml) as the rows the picker in
// functions/aliases.sh feeds to fzf.
//
// The table is TOML: one [group] per tool, one chord per key. A chord maps to
// an inline table { cmd, desc, run, eval } or to an array of them (a submenu:
// the same chord listed more than once, which the picker can only resolve by
// tab-selecting, since a duplicate never narrows to a single match).
//
//	cmd  (string, required)  shell text inserted into the line
//	desc (string)            breadcrumb shown next to the command
//	run  (bool, true)        accept the line at once; false leaves it for editing
//	eval (bool, false)       cmd prints the real command (fzf-backed helpers)
//
// Every row is six fields separated by U+00A0 (no-break space, which no
// chord, command or description may contain): the four display columns
// CHORD, CMD, GROUP, DESC, the first three padded to a common width, then the
// hidden RAWCMD and MODE, where MODE is one of run, insert, eval-run,
// eval-insert. With -width (the widget passes $COLUMNS) the CMD column is
// capped at what the terminal leaves after the other columns and a reserve
// for DESC, and longer commands are cut with an ellipsis, so one long entry
// cannot push the rest of the row off screen; RAWCMD is never cut. Rows keep
// file order, which the picker relies on (fzf --no-sort). A parse or
// validation error (unknown field, missing cmd, duplicate chord, wrong type)
// goes to stderr with exit status 1 so the widget can display it.
//
// Usage:
//
//	leader-aliases [-width COLUMNS] FILE
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/BurntSushi/toml"
)

// sep separates the fields of a rendered row. fzf splits on it (--delimiter)
// and renders it as a plain space.
const sep = "\u00a0"

// Layout budget applied when the terminal width is known: fzf draws a
// two-cell pointer gutter before each row, the description keeps up to
// descReserve cells (all of it when narrower), and the command column never
// shrinks below cmdFloor so a narrow pane still shows something useful.
const (
	gutter      = 2
	descReserve = 32
	cmdFloor    = 24
	ellipsis    = "…"
)

// entry is one chord binding: what to insert and how to dispatch it.
type entry struct {
	cmd  string
	desc string
	run  bool
	eval bool
}

// mode names the dispatch the widget performs: whether cmd is evaluated for
// the real command first, and whether the result is accepted or left in the
// line for editing.
func (e entry) mode() string {
	switch {
	case e.eval && e.run:
		return "eval-run"
	case e.eval:
		return "eval-insert"
	case e.run:
		return "run"
	default:
		return "insert"
	}
}

// row is an entry placed in the table: its chord and group.
type row struct {
	chord string
	group string
	entry
}

// display returns the visible columns in picker order.
func (r row) display() [4]string {
	return [4]string{r.chord, r.cmd, r.group, r.desc}
}

// checkText rejects text that would break the row format: the field
// separator or a line break.
func checkText(field, s string) error {
	if strings.ContainsAny(s, sep+"\t\n\r") {
		return fmt.Errorf("%s must not contain a tab, newline or no-break space", field)
	}
	return nil
}

// parseEntry validates one inline table against the four known fields.
func parseEntry(m map[string]any) (entry, error) {
	e := entry{run: true}
	for k, v := range m {
		switch k {
		case "cmd", "desc":
			s, ok := v.(string)
			if !ok {
				return e, fmt.Errorf("%s must be a string", k)
			}
			if err := checkText(k, s); err != nil {
				return e, err
			}
			if k == "cmd" {
				e.cmd = s
			} else {
				e.desc = s
			}
		case "run", "eval":
			b, ok := v.(bool)
			if !ok {
				return e, fmt.Errorf("%s must be a boolean", k)
			}
			if k == "run" {
				e.run = b
			} else {
				e.eval = b
			}
		default:
			return e, fmt.Errorf("unknown field %q (expected cmd, desc, run, eval)", k)
		}
	}
	if strings.TrimSpace(e.cmd) == "" {
		return e, errors.New("cmd is required")
	}
	return e, nil
}

// parseChord accepts a single entry table or a non-empty array of them (a
// submenu). The decoder yields either element type for an array depending on
// how it was written, so both are handled.
func parseChord(v any) ([]entry, error) {
	var tables []map[string]any
	switch t := v.(type) {
	case map[string]any:
		tables = []map[string]any{t}
	case []map[string]any:
		tables = t
	case []any:
		for _, x := range t {
			m, ok := x.(map[string]any)
			if !ok {
				return nil, errors.New("submenu items must be tables { cmd = ... }")
			}
			tables = append(tables, m)
		}
	default:
		return nil, errors.New("must be a table { cmd = ... } or an array of them")
	}
	if len(tables) == 0 {
		return nil, errors.New("submenu is empty")
	}
	entries := make([]entry, 0, len(tables))
	for i, m := range tables {
		e, err := parseEntry(m)
		if err != nil {
			if len(tables) > 1 {
				return nil, fmt.Errorf("[%d]: %w", i, err)
			}
			return nil, err
		}
		entries = append(entries, e)
	}
	return entries, nil
}

// parse decodes the table and returns its rows in file order. The decoder's
// key list is the only record of that order (maps lose it), so groups and
// chords are registered from it on first sight; a chord is rejected when it
// reappears under another group, since a submenu is an array under one chord.
func parse(src string) ([]row, error) {
	var top map[string]any
	md, err := toml.Decode(src, &top)
	if err != nil {
		return nil, err
	}

	var groups []string
	chords := map[string][]string{}
	seenGroup := map[string]bool{}
	seenChord := map[string]bool{}
	for _, k := range md.Keys() {
		if !seenGroup[k[0]] {
			seenGroup[k[0]] = true
			groups = append(groups, k[0])
		}
		if len(k) < 2 {
			continue
		}
		id := k[0] + "\x00" + k[1]
		if !seenChord[id] {
			seenChord[id] = true
			chords[k[0]] = append(chords[k[0]], k[1])
		}
	}

	var rows []row
	owner := map[string]string{}
	for _, g := range groups {
		if err := checkText("group", g); err != nil {
			return nil, fmt.Errorf("[%s]: %w", g, err)
		}
		table, ok := top[g].(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s: expected a [%s] table", g, g)
		}
		for _, c := range chords[g] {
			if c == "" {
				return nil, fmt.Errorf("[%s]: empty chord", g)
			}
			if err := checkText("chord", c); err != nil {
				return nil, fmt.Errorf("[%s]: %w", g, err)
			}
			if prev, dup := owner[c]; dup {
				return nil, fmt.Errorf("chord %q is defined in both [%s] and [%s]; a submenu is an array under one chord", c, prev, g)
			}
			owner[c] = g
			entries, err := parseChord(table[c])
			if err != nil {
				return nil, fmt.Errorf("%s.%s: %w", g, c, err)
			}
			for _, e := range entries {
				rows = append(rows, row{chord: c, group: g, entry: e})
			}
		}
	}
	return rows, nil
}

// pad right-pads s with spaces to width runes.
func pad(s string, width int) string {
	if n := utf8.RuneCountInString(s); n < width {
		return s + strings.Repeat(" ", width-n)
	}
	return s
}

// cmdWidth returns the display width of the command column given the natural
// column widths: the widest command, or, when the terminal width is known,
// what is left after the gutter, the chord and group columns, the three
// separators and the description reserve, bounded below by cmdFloor.
func cmdWidth(widths [4]int, termWidth int) int {
	natural := widths[1]
	if termWidth <= 0 {
		return natural
	}
	reserve := widths[3]
	if reserve > descReserve {
		reserve = descReserve
	}
	budget := termWidth - gutter - widths[0] - widths[2] - 3 - reserve
	if budget < cmdFloor {
		budget = cmdFloor
	}
	if budget > natural {
		return natural
	}
	return budget
}

// truncate cuts s to width runes, the last one an ellipsis marking the cut.
func truncate(s string, width int) string {
	if utf8.RuneCountInString(s) <= width {
		return s
	}
	return string([]rune(s)[:width-1]) + ellipsis
}

// render writes one row per entry: the display columns padded to a common
// width (the last one needs none), the command column fitted to termWidth
// when that is positive, then the raw command and mode.
func render(w io.Writer, rows []row, termWidth int) error {
	var widths [4]int
	for _, r := range rows {
		for i, s := range r.display() {
			if n := utf8.RuneCountInString(s); n > widths[i] {
				widths[i] = n
			}
		}
	}
	widths[1] = cmdWidth(widths, termWidth)
	for _, r := range rows {
		d := r.display()
		fields := []string{pad(d[0], widths[0]), pad(truncate(d[1], widths[1]), widths[1]), pad(d[2], widths[2]), d[3], r.cmd, r.mode()}
		if _, err := io.WriteString(w, strings.Join(fields, sep)+"\n"); err != nil {
			return err
		}
	}
	return nil
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "leader-aliases: %v\n", err)
	os.Exit(1)
}

func main() {
	width := flag.Int("width", 0, "terminal width in cells; fit the command column to it (0: no limit)")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: leader-aliases [-width COLUMNS] FILE")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	path := flag.Arg(0)
	src, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	rows, err := parse(string(src))
	if err != nil {
		fail(fmt.Errorf("%s: %w", path, err))
	}
	w := bufio.NewWriter(os.Stdout)
	if err := render(w, rows, *width); err != nil {
		fail(err)
	}
	if err := w.Flush(); err != nil {
		fail(err)
	}
}
