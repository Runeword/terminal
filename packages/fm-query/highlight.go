package main

// The two outputs: `fm-query rows` (fm_rg.sh's result list) and `fm-query
// mark` (fm_preview.sh's preview), both marking what query.go matches.

import (
	"bufio"
	"io"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// A long match line is shown as a window: its head is cut when the first mark
// starts past winFrom characters, keeping winLead before it, and at most
// winMax characters are shown.
const (
	winFrom = 40
	winLead = 16
	winMax  = 400
)

// Rows are held back and listed by path while the search ends within sortMax
// rows and sortWait, so a small search keeps its order from one keystroke to
// the next; past either, they stream in rg's order, handed to fzf every
// flushEvery. Variables for the tests.
var (
	sortMax    = 5000
	sortWait   = 150 * time.Millisecond
	flushEvery = 50 * time.Millisecond
)

// rows reads a record's first lineMax bytes only: a longer line (a minified
// file's, a source map's) is matched and shown by its head, so it costs no
// more than a short one, and a match past the head is not listed. A variable
// for the tests.
var lineMax = 64 << 10

// rows turns `rg --null --line-number` output (PATH NUL LINE:CODE per match)
// into fm_rg.sh's tab-delimited rows, keeping the lines that match the query:
// a bold header row per file, then one indented "line:code" row per match with
// the terms in bold cyan. Fields 2-4 carry the path, the line and the row's
// kind (H header, M match).
//
// It splits on the NUL, not the first colon, so a path holding ":" survives. A
// record without a NUL (rg's binary-file note, or the head of a name holding a
// newline, which fm_rg.sh excludes) is dropped, and so is a path holding a
// tab, a control character or invalid UTF-8: shown, it would name another
// file. A match's code is matched as rg read it, less a trailing CR, and shown
// with its control characters as symbols (see visible).
func rows(r io.Reader, out io.Writer, query string) error {
	q := parse(query)
	if !q.positive() {
		return nil
	}
	s := &rowsState{q: q, w: bufio.NewWriterSize(out, 64<<10), sorting: true}
	done := make(chan struct{})
	defer close(done)
	batches, errc := records(r, done)
	wait, tick := time.NewTimer(sortWait), time.NewTicker(flushEvery)
	defer wait.Stop()
	defer tick.Stop()
loop:
	for {
		var waitC <-chan time.Time
		if s.sorting {
			waitC = wait.C
		}
		select {
		case batch, ok := <-batches:
			if !ok {
				break loop
			}
			for len(batch) > 0 {
				rec := batch
				if i := strings.IndexByte(batch, '\n'); i >= 0 {
					rec, batch = batch[:i], batch[i+1:]
				} else {
					batch = ""
				}
				s.record(rec)
			}
			if s.sorting && s.held > sortMax {
				s.stream()
			}
		case <-waitC:
			s.stream()
		case <-tick.C:
			if !s.sorting && s.err == nil {
				s.err = s.w.Flush()
			}
		}
		if s.err != nil {
			return s.err
		}
	}
	if err := <-errc; err != nil {
		return err
	}
	if s.sorting {
		sort.SliceStable(s.blocks, func(i, j int) bool { return s.blocks[i].path < s.blocks[j].path })
		s.stream()
	}
	if s.err != nil {
		return s.err
	}
	return s.w.Flush()
}

// records reads r into batches of whole newline-terminated records, each cut
// to its first lineMax bytes (less a character the cut splits), and sends a
// batch once 32 KiB are read or nothing more is buffered, then reports the
// read error (nil at EOF). It stops early when done is closed. The batches
// are buffered so reading runs ahead of matching.
func records(r io.Reader, done <-chan struct{}) (<-chan string, <-chan error) {
	batches, errc := make(chan string, 64), make(chan error, 1)
	go func() {
		defer close(batches)
		br := bufio.NewReaderSize(r, 64<<10)
		var batch []byte
		start, cut := 0, false // where the record being read starts in batch; whether it was cut
		for {
			frag, err := br.ReadSlice('\n')
			nl := len(frag) > 0 && frag[len(frag)-1] == '\n'
			if nl {
				frag = frag[:len(frag)-1]
			}
			if !cut {
				if room := lineMax - (len(batch) - start); len(frag) > room {
					batch = append(batch, frag[:room]...)
					batch, cut = batch[:start+whole(batch[start:])], true
				} else {
					batch = append(batch, frag...)
				}
			}
			if nl {
				batch = append(batch, '\n')
			}
			if err == bufio.ErrBufferFull {
				continue // the rest of a long record follows
			}
			start, cut = len(batch), false
			if len(batch) > 0 && (err != nil || len(batch) >= 32<<10 || br.Buffered() == 0) {
				select {
				case batches <- string(batch):
				case <-done:
					return
				}
				batch, start = batch[:0], 0
			}
			if err != nil {
				if err == io.EOF {
					err = nil
				}
				errc <- err
				return
			}
		}
	}()
	return batches, errc
}

// whole returns the length of b less a character its end cuts short.
func whole(b []byte) int {
	for i := len(b) - 1; i >= 0 && i >= len(b)-utf8.UTFMax; i-- {
		if utf8.RuneStart(b[i]) {
			if utf8.FullRune(b[i:]) {
				return len(b)
			}
			return i
		}
	}
	return len(b)
}

// block is one file's rows, held back while sorting.
type block struct {
	path string
	buf  []byte
}

type rowsState struct {
	q       query
	w       *bufio.Writer
	err     error
	sorting bool
	blocks  []block
	held    int
	path    string // the file of the last row
	headed  bool   // its header is out
	l       line
	m       []bool
	row     []byte
	out     []byte
}

// record turns one rg record (its newline removed) into a row, if its line
// matches.
func (s *rowsState) record(rec string) {
	path, rest, ok := strings.Cut(rec, "\x00")
	if !ok || !validPath(path) {
		return
	}
	num, code, ok := strings.Cut(rest, ":")
	if !ok {
		num, code = "", rest
	}
	s.l.reset(strings.TrimSuffix(code, "\r"))
	if !s.q.accepts(&s.l) {
		return
	}
	s.m = marks(s.m, len(s.l.raw))
	s.q.mark(&s.l, s.m)

	n, first := len(s.l.raw), -1
	for i, on := range s.m {
		if on {
			first = i
			break
		}
	}
	from := 0
	if first > winFrom {
		from = first - winLead
	}
	to := min(n, from+winMax)
	row := append(s.row[:0], "  "...)
	row = append(row, num...)
	row = append(row, ':')
	if from > 0 {
		row = append(row, "…"...)
	}
	row = s.l.paint(row, s.m, from, to, "\033[1;36m", "\033[0m")
	if to < n {
		row = append(row, "…"...)
	}
	row = append(row, '\t')
	row = append(row, path...)
	row = append(row, '\t')
	row = append(row, num...)
	row = append(row, "\tM\n"...)
	s.row = row
	s.add(path, num, row)
}

// add puts row out, after its file's header when it is the file's first.
func (s *rowsState) add(path, num string, row []byte) {
	if path != s.path {
		s.path, s.headed = path, false
		if s.sorting {
			s.blocks = append(s.blocks, block{path: path})
		}
	}
	b := s.out[:0]
	if s.sorting {
		b = s.blocks[len(s.blocks)-1].buf
	}
	if !s.headed {
		// The header carries the first match's line, for the preview.
		b = append(b, "\033[1;35m"...)
		b = append(b, path...)
		b = append(b, "\033[0m\t"...)
		b = append(b, path...)
		b = append(b, '\t')
		b = append(b, num...)
		b = append(b, "\tH\n"...)
		s.headed = true
	}
	b = append(b, row...)
	if s.sorting {
		s.blocks[len(s.blocks)-1].buf = b
		s.held++
		return
	}
	s.write(b)
	s.out = b
}

// stream puts out the rows held back, in their current order, and lets the
// next ones through as they come.
func (s *rowsState) stream() {
	s.sorting = false
	for _, b := range s.blocks {
		s.write(b.buf)
	}
	s.blocks, s.held = nil, 0
}

func (s *rowsState) write(b []byte) {
	if s.err == nil {
		_, s.err = s.w.Write(b)
	}
}

// marks returns n cleared flags, reusing m.
func marks(m []bool, n int) []bool {
	if cap(m) < n {
		return make([]bool, n)
	}
	m = m[:n]
	clear(m)
	return m
}

// paint appends characters [from, to) of l to b as visible text, every
// marked run wrapped in on/off.
func (l *line) paint(b []byte, m []bool, from, to int, on, off string) []byte {
	in := false
	for i := from; i < to; i++ {
		if m[i] != in {
			in = m[i]
			if in {
				b = append(b, on...)
			} else {
				b = append(b, off...)
			}
		}
		b = utf8.AppendRune(b, visible(l.raw[i]))
	}
	if in {
		b = append(b, off...)
	}
	return b
}

// visible is the character a row shows for r: a tab as a space (it would add
// a field), another C0 control or DEL as its Control Pictures symbol (␛), a C1
// control as U+FFFD -- so no escape sequence from a file reaches fzf, and
// every character keeps its place for the marks. Invalid UTF-8 was decoded to
// U+FFFD already.
func visible(r rune) rune {
	switch {
	case r == '\t':
		return ' '
	case r < 0x20:
		return 0x2400 + r
	case r == 0x7f:
		return 0x2421
	case r >= 0x80 && r < 0xa0:
		return utf8.RuneError
	}
	return r
}

// validPath reports whether p can be listed as is: valid UTF-8 without
// control characters.
func validPath(p string) bool {
	if !utf8.ValidString(p) {
		return false
	}
	for _, r := range p {
		if r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0 {
			return false
		}
	}
	return true
}

// mark reverse-videos the query's terms in already-colored text (fm_preview.sh's
// tree-sitter or bat output), line by line. Escape sequences are copied verbatim
// and never matched inside (see escLen); reverse is re-asserted after one inside
// a run, so a mid-run reset can't drop it. A query without positive terms
// copies r as is.
func mark(r io.Reader, out io.Writer, query string) error {
	q := parse(query)
	if !q.positive() {
		_, err := io.Copy(out, r)
		return err
	}
	const on, off = "\033[7m", "\033[27m"
	type piece struct {
		esc      bool
		s        string
		from, to int // a plain piece's characters in the line's text
	}
	br := bufio.NewReaderSize(r, 64<<10)
	w := bufio.NewWriterSize(out, 64<<10)
	var (
		l      line
		plain  strings.Builder
		pieces []piece
		m      []bool
		buf    []byte
	)
	for {
		s, err := br.ReadString('\n')
		if len(s) > 0 {
			nl := strings.HasSuffix(s, "\n")
			s = strings.TrimSuffix(s, "\n")
			// The plain pieces are matched as one text, so a term can span a
			// color change; each is decoded on its own, so no character spans
			// an escape.
			pieces = pieces[:0]
			l.begin()
			plain.Reset()
			for rest := s; rest != ""; {
				if rest[0] == '\033' {
					n := escLen(rest)
					pieces = append(pieces, piece{esc: true, s: rest[:n]})
					rest = rest[n:]
					continue
				}
				n := strings.IndexByte(rest, '\033')
				if n < 0 {
					n = len(rest)
				}
				from := len(l.raw)
				l.add(rest[:n], plain.Len())
				plain.WriteString(rest[:n])
				pieces = append(pieces, piece{s: rest[:n], from: from, to: len(l.raw)})
				rest = rest[n:]
			}
			l.s = plain.String()
			l.end()
			m = marks(m, len(l.raw))
			q.mark(&l, m)
			buf = buf[:0]
			in := false
			for _, p := range pieces {
				if p.esc {
					buf = append(buf, p.s...)
					if in {
						buf = append(buf, on...)
					}
					continue
				}
				for i := p.from; i < p.to; i++ {
					if m[i] != in {
						in = m[i]
						if in {
							buf = append(buf, on...)
						} else {
							buf = append(buf, off...)
						}
					}
					buf = append(buf, l.s[l.at[i]:l.at[i+1]]...)
				}
			}
			if in {
				buf = append(buf, off...)
			}
			if nl {
				buf = append(buf, '\n')
			}
			if _, werr := w.Write(buf); werr != nil {
				return werr
			}
		}
		if err == io.EOF {
			return w.Flush()
		}
		if err != nil {
			return err
		}
	}
}

// escLen is the length of the escape sequence s starts with (s[0] is ESC), per
// ECMA-48: a CSI (parameter bytes, intermediate bytes, a final byte), a
// string (OSC, DCS, SOS, PM, APC) up to BEL or ST, or a two-byte or nF escape.
// A malformed one counts as a lone ESC; an unterminated string runs to the end.
func escLen(s string) int {
	if len(s) < 2 {
		return 1
	}
	switch c := s[1]; {
	case c == '[':
		i := 2
		for i < len(s) && s[i] >= 0x30 && s[i] <= 0x3f {
			i++
		}
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x2f {
			i++
		}
		if i < len(s) && s[i] >= 0x40 && s[i] <= 0x7e {
			return i + 1
		}
	case c == ']' || c == 'P' || c == 'X' || c == '^' || c == '_':
		for i := 2; i < len(s); i++ {
			if s[i] == 0x07 {
				return i + 1
			}
			if s[i] == '\033' && i+1 < len(s) && s[i+1] == '\\' {
				return i + 2
			}
		}
		return len(s)
	case c >= 0x20 && c <= 0x2f:
		i := 2
		for i < len(s) && s[i] >= 0x20 && s[i] <= 0x2f {
			i++
		}
		if i < len(s) && s[i] >= 0x30 && s[i] <= 0x7e {
			return i + 1
		}
	case c >= 0x30 && c <= 0x7e:
		return 2
	}
	return 1
}
