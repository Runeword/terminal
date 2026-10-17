// Command leader-aliases renders the leader-key table
// (sources/.config/shell/leader.conf) as the rows the picker in
// functions/aliases.sh feeds to fzf, and with -fmt lines up its columns.
//
// The table is plain text, one chord per line, in four columns:
//
//	chord  mode  description  command
//
// The first three end at a tab or at two or more spaces, so a description can
// hold single spaces; the command is the rest of the line and can hold
// anything. The mode is one of
//
//	run        insert the command and run it
//	edit       insert the command and leave it for editing
//	eval       run the command, which prints the real one (fzf-backed
//	           helpers), then insert that and run it
//	eval-edit  the same, leaving the printed command for editing
//
// A [name] line starts a group, which the chords below it belong to; a line
// starting with # is a comment; blank lines are ignored. The chord <space> is
// the space key. A chord listed on adjacent lines is a submenu, which the
// picker can only resolve by tab-selecting, since the chord never narrows to
// a single row.
//
// Every row is six fields separated by U+00A0 (no-break space, which no
// chord, command or description may contain): the four display columns
// CHORD, CMD, GROUP, DESC, the first three padded to a common width, then the
// hidden RAWCMD and MODE, where MODE is one of run, insert, eval-run,
// eval-insert. With -width (the widget passes $COLUMNS) the CMD column is
// capped at what the terminal leaves after the other columns and a reserve
// for DESC, and longer commands are cut with an ellipsis, so one long entry
// cannot push the rest of the row off screen; RAWCMD is never cut. Rows keep
// file order, which the picker relies on (fzf --no-sort).
//
// -fmt rewrites the table in place: each run of consecutive chord lines is
// aligned on its own, its first three cells padded with spaces and ended with
// a tab, so the columns line up at any tab width; comments, blank lines and
// group lines are kept. The file is written only when that changes it, and
// over itself, so it keeps its inode (a sandbox pin bind-mounts it). With -
// for FILE it formats standard input to standard output.
//
// An error (wrong column count, unknown mode, a chord in two groups, a
// submenu split apart, ...) goes to stderr as FILE:LINE: and exit status 1,
// so the widget can display it and __leader_edit can reopen the line.
//
// Usage:
//
//	leader-aliases [-width COLUMNS] FILE
//	leader-aliases -fmt FILE
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"
)

// sep separates the fields of a rendered row. fzf splits on it (--delimiter)
// and renders it as a plain space.
const sep = " "

// spaceChord is how the table writes the space key, which a blank-separated
// column cannot hold.
const spaceChord = "<space>"

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

// modes maps the table's mode words to the dispatch they name.
var modes = map[string]entry{
	"run":       {run: true},
	"edit":      {},
	"eval":      {run: true, eval: true},
	"eval-edit": {eval: true},
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

// line is one line of the table as the formatter rewrites it: a chord line's
// four cells as written, or any other line's text.
type line struct {
	cells [4]string
	chord bool
	text  string
}

// checkText rejects text that would break the row format: the field
// separator or a line break.
func checkText(field, s string) error {
	if strings.ContainsAny(s, sep+"\t\n\r") {
		return fmt.Errorf("%s must not contain a tab, newline or no-break space", field)
	}
	return nil
}

// separator returns the bounds of the first run of blanks in s that holds a
// tab or at least two spaces, or -1, -1 when there is none.
func separator(s string) (int, int) {
	for i := 0; i < len(s); {
		if s[i] != ' ' && s[i] != '\t' {
			i++
			continue
		}
		j, tab := i, false
		for j < len(s) && (s[j] == ' ' || s[j] == '\t') {
			tab = tab || s[j] == '\t'
			j++
		}
		if tab || j-i >= 2 {
			return i, j
		}
		i = j
	}
	return -1, -1
}

// splitCells cuts a trimmed chord line into chord, mode, description and
// command: the first three end at a separator, the command is the rest.
func splitCells(s string) ([4]string, bool) {
	var cells [4]string
	for i := 0; i < 3; i++ {
		start, end := separator(s)
		if start < 0 {
			return cells, false
		}
		cells[i], s = s[:start], s[end:]
	}
	cells[3] = s
	return cells, true
}

// parse reads the table and returns its rows in file order, and its lines for
// the formatter. Errors start with name:LINE:.
func parse(name, src string) ([]row, []line, error) {
	var (
		rows   []row
		lines  []line
		group  string
		groups = map[string]int{}    // group -> line it starts on
		owner  = map[string]string{} // chord -> its group
		first  = map[string]int{}    // chord -> its first line
		last   string                // chord of the latest chord line
	)
	texts := strings.Split(strings.TrimSuffix(src, "\n"), "\n")
	if src == "" {
		texts = nil
	}
	for i, text := range texts {
		n := i + 1
		fail := func(format string, a ...any) ([]row, []line, error) {
			return nil, nil, fmt.Errorf("%s:%d: %s", name, n, fmt.Sprintf(format, a...))
		}
		t := strings.Trim(text, " \t\r")
		switch {
		case t == "":
			lines = append(lines, line{})
		case t[0] == '#':
			lines = append(lines, line{text: strings.TrimRight(text, " \t\r")})
		case t[0] == '[':
			if t[len(t)-1] != ']' {
				return fail("a group line is [name] alone")
			}
			g := strings.TrimSpace(t[1 : len(t)-1])
			if g == "" {
				return fail("empty group name")
			}
			if err := checkText("a group name", g); err != nil {
				return fail("%v", err)
			}
			if prev, dup := groups[g]; dup {
				return fail("[%s] is already on line %d", g, prev)
			}
			groups[g], group = n, g
			lines = append(lines, line{text: "[" + g + "]"})
		default:
			if group == "" {
				return fail("a chord line before any [group] line")
			}
			cells, ok := splitCells(t)
			if !ok {
				return fail("expected four columns: chord, mode, description, command, separated by a tab or two spaces")
			}
			chord := cells[0]
			if chord == spaceChord {
				chord = " "
			} else if strings.Contains(chord, " ") {
				return fail("chord %q holds a space: write %s for the space key", chord, spaceChord)
			}
			if err := checkText("a chord", chord); err != nil {
				return fail("%v", err)
			}
			e, ok := modes[cells[1]]
			if !ok {
				return fail("unknown mode %q (expected run, edit, eval or eval-edit)", cells[1])
			}
			for _, f := range [][2]string{{"a description", cells[2]}, {"a command", cells[3]}} {
				if err := checkText(f[0], f[1]); err != nil {
					return fail("%v", err)
				}
			}
			if prev, dup := owner[chord]; dup {
				if prev != group {
					return fail("chord %q is already in [%s] (line %d); a submenu is adjacent lines of one chord", cells[0], prev, first[chord])
				}
				if last != chord {
					return fail("chord %q is already on line %d; the lines of a submenu must be adjacent", cells[0], first[chord])
				}
			} else {
				owner[chord], first[chord] = group, n
			}
			last = chord
			e.desc, e.cmd = cells[2], cells[3]
			rows = append(rows, row{chord: chord, group: group, entry: e})
			lines = append(lines, line{cells: cells, chord: true})
		}
	}
	return rows, lines, nil
}

// format returns the table with each run of consecutive chord lines aligned:
// a chord, mode or description is padded with spaces to the widest in its run
// plus one, then ended with a tab. Other lines are kept as they are.
func format(lines []line) string {
	var b strings.Builder
	for i := 0; i < len(lines); {
		if !lines[i].chord {
			b.WriteString(lines[i].text)
			b.WriteByte('\n')
			i++
			continue
		}
		j := i
		var widths [3]int
		for ; j < len(lines) && lines[j].chord; j++ {
			for k := range widths {
				widths[k] = max(widths[k], utf8.RuneCountInString(lines[j].cells[k]))
			}
		}
		for ; i < j; i++ {
			c := lines[i].cells
			for k := range widths {
				b.WriteString(pad(c[k], widths[k]+1))
				b.WriteByte('\t')
			}
			b.WriteString(c[3])
			b.WriteByte('\n')
		}
	}
	return b.String()
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

// formatFile rewrites the table at path in its canonical form, over itself and
// only when that changes it; "-" formats standard input to standard output.
func formatFile(path string) error {
	if path == "-" {
		src, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		_, lines, err := parse("<stdin>", string(src))
		if err != nil {
			return err
		}
		_, err = io.WriteString(os.Stdout, format(lines))
		return err
	}
	src, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	_, lines, err := parse(path, string(src))
	if err != nil {
		return err
	}
	out := format(lines)
	if out == string(src) {
		return nil
	}
	return os.WriteFile(path, []byte(out), 0o644)
}

func fail(err error) {
	fmt.Fprintf(os.Stderr, "leader-aliases: %v\n", err)
	os.Exit(1)
}

func main() {
	width := flag.Int("width", 0, "terminal width in cells; fit the command column to it (0: no limit)")
	fmtFlag := flag.Bool("fmt", false, "line up the table's columns in place (FILE - : stdin to stdout)")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: leader-aliases [-width COLUMNS] FILE\n       leader-aliases -fmt FILE")
		flag.PrintDefaults()
	}
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	path := flag.Arg(0)
	if *fmtFlag {
		if err := formatFile(path); err != nil {
			fail(err)
		}
		return
	}
	src, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	rows, _, err := parse(path, string(src))
	if err != nil {
		fail(err)
	}
	w := bufio.NewWriter(os.Stdout)
	if err := render(w, rows, *width); err != nil {
		fail(err)
	}
	if err := w.Flush(); err != nil {
		fail(err)
	}
}
