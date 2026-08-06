// Command tmux-sessions is a fuzzy session switcher driven by Alt+Tab.
//
// It is meant to be run inside a tmux popup:
//
//	bind -n M-Tab display-popup -E -w 60 -h 40% 'tmux-sessions'
//
// Sessions are listed most-recently-used first and the selection opens on the
// *previous* session, so tapping Alt+Tab and pressing Enter toggles between
// the last two — the desktop window-switcher idiom. Every move switches the
// client immediately, so the session behind the popup is always the one under
// the cursor; Escape puts you back where you started.
//
// It exists because fzf cannot bind alt-tab ("unsupported key"), which makes
// the intended keystroke impossible to implement with a generic picker. See
// keys.go for the encodings Alt+Tab actually arrives in.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// How long to wait after a lone ESC before concluding it was Escape rather
// than the first byte of an Alt+<key> sequence.
const escDelay = 40 * time.Millisecond

// Palette lifted from tmux.conf so the popup reads as part of the status bar.
const (
	dim     = "\x1b[38;2;122;124;158m"
	bright  = "\x1b[38;2;255;255;255m"
	accent  = "\x1b[38;2;74;74;168m"
	reset   = "\x1b[0m"
	under   = "\x1b[4m"
	noUnder = "\x1b[24m"
)

type row struct {
	session
	positions []int // matched name offsets, for highlighting
}

type ui struct {
	all      []session
	rows     []row
	query    []rune
	selected int
	offset   int // first visible row, for scrolling
	origin   string
	live     bool
	out      *os.File
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--keys" {
		if err := keyReport(); err != nil {
			fmt.Fprintln(os.Stderr, "tmux-sessions:", err)
			os.Exit(1)
		}
		return
	}

	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "tmux-sessions:", err)
		os.Exit(1)
	}
}

func run() error {
	sessions, err := listSessions()
	if err != nil {
		return fmt.Errorf("listing sessions: %w", err)
	}
	if len(sessions) == 0 {
		return fmt.Errorf("no tmux sessions")
	}

	u := &ui{
		all:    sessions,
		origin: currentSession(),
		live:   insideTmux(),
		out:    os.Stdout,
	}
	u.filter()

	// Open on the previous session, not the current one — that is what makes a
	// bare Alt+Tab, Enter a toggle between the last two sessions.
	if len(u.rows) > 1 {
		u.selected = 1
	}

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return fmt.Errorf("opening tty: %w", err)
	}
	// Errors are ignored on this Close and on every write to the terminal below.
	// A tty is unbuffered, so Close has nothing left to flush and nothing to
	// report; and a write that fails means the terminal is gone, which the loop
	// detects one step later when its read fails and returns. Checking here would
	// either duplicate that or — in restore() — try to report the failure into
	// the very terminal that just proved unwritable.
	defer func() { _ = tty.Close() }()

	state, err := makeRaw(tty)
	if err != nil {
		return fmt.Errorf("raw mode: %w", err)
	}

	// Restore on the way out however we leave, including a panic — a popup
	// that dies in raw mode with the cursor hidden leaves the pane unusable.
	restore := func() {
		_, _ = fmt.Fprint(u.out, "\x1b[?25h\x1b[?1049l")
		state.restore()
	}
	defer restore()

	_, _ = fmt.Fprint(u.out, "\x1b[?1049h\x1b[?25l")

	u.syncClient()
	return u.loop(tty)
}

func (u *ui) loop(tty *os.File) error {
	in := make(chan []byte, 8)
	go func() {
		defer close(in)
		buf := make([]byte, 256)
		for {
			n, err := tty.Read(buf)
			if n > 0 {
				chunk := make([]byte, n)
				copy(chunk, buf[:n])
				in <- chunk
			}
			if err != nil {
				return
			}
		}
	}()

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)

	var pending []byte
	u.render()

	for {
		k := decode(pending, false)

		// Gather bytes until the sequence resolves. A lone ESC resolves only
		// once escDelay expires with nothing following it.
		for k.kind == keyIncomplete {
			var deadline <-chan time.Time
			if len(pending) > 0 {
				deadline = time.After(escDelay)
			}
			select {
			case chunk, ok := <-in:
				if !ok {
					return nil
				}
				pending = append(pending, chunk...)
				k = decode(pending, false)
			case <-deadline:
				k = decode(pending, true)
			case <-winch:
				u.render()
			}
		}
		pending = pending[k.n:]

		switch k.kind {
		case keyNext:
			u.move(1)
		case keyPrev:
			u.move(-1)
		case keyRune:
			u.query = append(u.query, k.r)
			u.refilter()
		case keyBackspace:
			if len(u.query) > 0 {
				u.query = u.query[:len(u.query)-1]
				u.refilter()
			}
		case keyClearLine:
			if len(u.query) > 0 {
				u.query = u.query[:0]
				u.refilter()
			}
		case keyClearWord:
			if n := len(trimWord(u.query)); n != len(u.query) {
				u.query = trimWord(u.query)
				u.refilter()
			}
		case keyAccept:
			// The client already follows the selection, so accepting is just
			// leaving without rewinding.
			return nil
		case keyCancel:
			if u.live && u.origin != "" {
				_ = switchTo(u.origin)
			}
			return nil
		case keyNone:
			continue
		}
		u.render()
	}
}

// move cycles the selection, wrapping at both ends so holding Alt and tapping
// Tab walks the list round and round.
func (u *ui) move(delta int) {
	if len(u.rows) == 0 {
		return
	}
	u.selected = (u.selected + delta + len(u.rows)) % len(u.rows)
	u.syncClient()
}

func (u *ui) refilter() {
	u.filter()
	u.selected, u.offset = 0, 0
	u.syncClient()
}

// filter recomputes the visible rows for the current query, best match first.
func (u *ui) filter() {
	q := string(u.query)
	u.rows = u.rows[:0]

	if q == "" {
		for _, s := range u.all {
			u.rows = append(u.rows, row{session: s})
		}
		return
	}

	type scored struct {
		row
		score int
	}
	var hits []scored

	for _, s := range u.all {
		if m, ok := fuzzy(q, s.name); ok {
			hits = append(hits, scored{row{s, m.positions}, m.score})
			continue
		}
		// Fall back to the working directory, so "nix" finds a session named
		// "3" sitting in ~/nixos. Ranked below name matches.
		if m, ok := fuzzy(q, homePath(s.path)); ok {
			hits = append(hits, scored{row{session: s}, m.score - 40})
		}
	}

	// Insertion sort: the list is a handful of sessions, and a stable sort
	// keeps MRU order intact between equal scores.
	for i := 1; i < len(hits); i++ {
		for j := i; j > 0 && hits[j].score > hits[j-1].score; j-- {
			hits[j], hits[j-1] = hits[j-1], hits[j]
		}
	}
	for _, h := range hits {
		u.rows = append(u.rows, h.row)
	}
}

// syncClient makes the session behind the popup follow the selection.
func (u *ui) syncClient() {
	if !u.live || u.selected >= len(u.rows) {
		return
	}
	_ = switchTo(u.rows[u.selected].name)
}

func (u *ui) render() {
	rows, cols := size(u.out)
	if cols < 8 || rows < 3 {
		return
	}

	// Reserve the query line plus the blank lines framing it.
	const chrome = 3
	view := rows - chrome
	if view < 1 {
		view = 1
	}
	u.scrollTo(view)

	var b strings.Builder
	b.WriteString("\x1b[H\x1b[2J")

	b.WriteString("\r\n  ")
	b.WriteString(bright + string(u.query) + reset)
	b.WriteString(accent + "▏" + reset)
	u.writeCount(&b, cols)
	b.WriteString("\r\n\r\n")

	end := min(u.offset+view, len(u.rows))
	for i := u.offset; i < end; i++ {
		u.writeRow(&b, i, cols)
	}

	if len(u.rows) == 0 {
		b.WriteString("  " + dim + "no match" + reset)
	}

	_, _ = fmt.Fprint(u.out, b.String())
}

// writeCount right-aligns "shown/total", omitting it when nothing is filtered
// or the popup is too narrow to hold it without colliding with the query.
func (u *ui) writeCount(b *strings.Builder, cols int) {
	if len(u.rows) == len(u.all) {
		return
	}
	label := fmt.Sprintf("%d/%d", len(u.rows), len(u.all))
	used := 3 + len(u.query)
	pad := cols - used - len(label) - 2
	if pad < 2 {
		return
	}
	b.WriteString(strings.Repeat(" ", pad) + dim + label + reset)
}

func (u *ui) writeRow(b *strings.Builder, i, cols int) {
	r := u.rows[i]
	selected := i == u.selected

	if selected {
		b.WriteString(accent + "  ▌ " + reset + bright)
	} else {
		b.WriteString("    " + dim)
	}

	// Name column, wide enough to keep the metadata aligned but never so wide
	// that it crowds a narrow popup.
	nameW := min(20, max(8, cols/3))
	b.WriteString(highlight(r.name, r.positions, nameW))
	b.WriteString(reset)

	meta := fmt.Sprintf("%s  %s", r.windows, homePath(r.path))
	room := cols - 4 - nameW - 2
	if room > 4 {
		b.WriteString(dim + "  " + truncate(meta, room) + reset)
	}
	b.WriteString("\r\n")
}

// scrollTo keeps the selection inside the visible window.
func (u *ui) scrollTo(view int) {
	if u.selected < u.offset {
		u.offset = u.selected
	}
	if u.selected >= u.offset+view {
		u.offset = u.selected - view + 1
	}
	if u.offset < 0 {
		u.offset = 0
	}
}

// highlight underlines the matched characters and pads to width. Underline is
// used rather than a colour so it reads the same on the selected row (white)
// and the unselected rows (dim).
func highlight(s string, positions []int, width int) string {
	runes := []rune(s)
	if len(runes) > width {
		runes = runes[:max(1, width-1)]
		runes = append(runes, '…')
	}

	hit := make(map[int]bool, len(positions))
	for _, p := range positions {
		hit[p] = true
	}

	var b strings.Builder
	on := false
	for i, r := range runes {
		switch {
		case hit[i] && !on:
			b.WriteString(under)
			on = true
		case !hit[i] && on:
			b.WriteString(noUnder)
			on = false
		}
		b.WriteRune(r)
	}
	if on {
		b.WriteString(noUnder)
	}
	if pad := width - len(runes); pad > 0 {
		b.WriteString(strings.Repeat(" ", pad))
	}
	return b.String()
}

func truncate(s string, width int) string {
	runes := []rune(s)
	if len(runes) <= width {
		return s
	}
	if width < 1 {
		return ""
	}
	return string(runes[:width-1]) + "…"
}

func trimWord(q []rune) []rune {
	i := len(q)
	for i > 0 && q[i-1] == ' ' {
		i--
	}
	for i > 0 && q[i-1] != ' ' {
		i--
	}
	return q[:i]
}

// keyReport dumps decoded keystrokes, so it can be confirmed that Alt+Tab
// actually reaches the terminal rather than being swallowed by the window
// manager — the usual reason the binding appears dead.
func keyReport() error {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	// Best-effort, as in run(): this is a diagnostic dump into the terminal the
	// user is watching, so a write that fails has no one left to tell.
	defer func() { _ = tty.Close() }()

	state, err := makeRaw(tty)
	if err != nil {
		return err
	}
	defer state.restore()

	names := map[keyKind]string{
		keyNone: "unbound", keyRune: "rune", keyNext: "NEXT", keyPrev: "PREV",
		keyAccept: "accept", keyCancel: "cancel", keyBackspace: "backspace",
		keyClearLine: "clear-line", keyClearWord: "clear-word",
	}

	_, _ = fmt.Fprint(tty, "press keys — Alt+Tab should report NEXT; ctrl-c to quit\r\n")

	buf := make([]byte, 256)
	for {
		n, err := tty.Read(buf)
		if err != nil {
			return nil
		}
		b := buf[:n]
		k := decode(b, true)
		if k.kind == keyCancel && n == 1 && b[0] == 0x03 {
			return nil
		}
		_, _ = fmt.Fprintf(tty, "% x  ->  %s %s\r\n", b, names[k.kind], string(k.r))
	}
}
