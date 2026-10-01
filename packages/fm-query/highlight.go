package main

// The highlighters behind `fm-query rows` (fm_rg.sh's result list) and
// `fm-query mark` (fm_preview.sh's preview). Both mark the query's positive
// terms with one matcher: an exact term covers every occurrence of its text
// (overlaps included), a fuzzy term the leftmost run of its characters in
// order (like fzf), and only if all of them are found. Text is matched per
// character, and invalid UTF-8 bytes count as one character each and are copied
// through unchanged.

import (
	"bufio"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

// term is one positive query term, folded to lower case when the search is
// case-insensitive.
type term struct {
	fuzzy bool
	text  []rune
}

// highlighter holds a query's terms and its case rule.
type highlighter struct {
	terms []term
	fold  bool
}

// newHighlighter compiles query and keeps its highlight terms. Smart-case is
// global, as for rg in fm_rg.sh: any ASCII uppercase letter anywhere (its
// `*[A-Z]*` test) makes the whole query case-sensitive.
func newHighlighter(query string) highlighter {
	h := highlighter{fold: !strings.ContainsAny(query, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")}
	_, spec := compile(query)
	for _, e := range strings.Split(spec, "\t") {
		if len(e) < 3 {
			continue
		}
		h.terms = append(h.terms, term{fuzzy: e[0] == 'F', text: h.runes(e[2:])})
	}
	return h
}

// runes decodes s into its characters, folded if the search ignores case.
func (h highlighter) runes(s string) []rune {
	rs := []rune(s)
	if h.fold {
		for i, r := range rs {
			rs[i] = unicode.ToLower(r)
		}
	}
	return rs
}

// marks reports, per character of text (as split by chars), whether a term
// covers it.
func (h highlighter) marks(text []rune) []bool {
	m := make([]bool, len(text))
	for _, t := range h.terms {
		n := len(t.text)
		if !t.fuzzy {
			for i := 0; i+n <= len(text); i++ {
				if equalRunes(text[i:i+n], t.text) {
					for j := i; j < i+n; j++ {
						m[j] = true
					}
				}
			}
			continue
		}
		seq := make([]int, 0, n)
		p := 0
		for _, c := range t.text {
			for p < len(text) && text[p] != c {
				p++
			}
			if p == len(text) {
				seq = nil
				break
			}
			seq = append(seq, p)
			p++
		}
		for _, i := range seq {
			m[i] = true
		}
	}
	return m
}

func equalRunes(a, b []rune) bool {
	for i := range b {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// chars splits s into characters: the runes to match (folded as the search
// requires) and each one's byte offset in s, plus len(s), so s[at[i]:at[i+1]]
// is character i verbatim.
func (h highlighter) chars(s string) (text []rune, at []int) {
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if h.fold {
			r = unicode.ToLower(r)
		}
		text = append(text, r)
		at = append(at, i)
		i += size
	}
	return text, append(at, len(s))
}

// paint appends s to b with every marked run wrapped in on/off.
func (h highlighter) paint(b *strings.Builder, s, on, off string) {
	text, at := h.chars(s)
	m := h.marks(text)
	in := false
	for i := range text {
		if m[i] != in {
			in = m[i]
			if in {
				b.WriteString(on)
			} else {
				b.WriteString(off)
			}
		}
		b.WriteString(s[at[i]:at[i+1]])
	}
	if in {
		b.WriteString(off)
	}
}

// eachLine writes to out what fn makes of every line of r, given without its
// newline and whether it had one (only a final line can lack it).
func eachLine(r io.Reader, out io.Writer, fn func(b *strings.Builder, line string, nl bool)) error {
	br := bufio.NewReaderSize(r, 64<<10)
	w := bufio.NewWriterSize(out, 64<<10)
	var b strings.Builder
	for {
		line, err := br.ReadString('\n')
		if len(line) > 0 {
			b.Reset()
			fn(&b, strings.TrimSuffix(line, "\n"), strings.HasSuffix(line, "\n"))
			if _, werr := w.WriteString(b.String()); werr != nil {
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

// rows turns `rg --null --line-number` output (PATH NUL LINE:CODE per match)
// into fm_rg.sh's tab-delimited rows: a bold header row per file, then one
// indented "line:code" row per match with the terms in bold cyan. Fields 2-4
// carry the path, the line and the row's kind (H header, M match). It splits
// on the NUL, not the first colon, so a path holding ":" survives, and squashes
// tabs in path and code so neither adds fields. A record without a NUL is the
// head of a file name holding a newline (rg still ends records with one), and
// is dropped rather than shown as a phantom row.
func rows(r io.Reader, out io.Writer, query string) error {
	h := newHighlighter(query)
	cur := ""
	return eachLine(r, out, func(b *strings.Builder, rec string, _ bool) {
		path, rest, ok := strings.Cut(rec, "\x00")
		if !ok {
			return
		}
		path = strings.ReplaceAll(path, "\t", " ")
		line, code, ok := strings.Cut(rest, ":")
		if !ok {
			line, code = "", rest
		}
		if path != cur {
			cur = path
			b.WriteString("\033[1;35m" + path + "\033[0m\t" + path + "\t" + line + "\tH\n")
		}
		b.WriteString("  " + line + ":")
		h.paint(b, strings.ReplaceAll(code, "\t", " "), "\033[1;36m", "\033[0m")
		b.WriteString("\t" + path + "\t" + line + "\tM\n")
	})
}

// mark reverse-videos the terms in already-colored text (fm_preview.sh's
// tree-sitter or bat output). Escape sequences (CSI, or a lone ESC) are copied
// verbatim and never matched inside; reverse is re-asserted after one inside a
// run, so a mid-run reset can't drop it. A query without terms copies r as is.
func mark(r io.Reader, out io.Writer, query string) error {
	h := newHighlighter(query)
	if len(h.terms) == 0 {
		_, err := io.Copy(out, r)
		return err
	}
	const on, off = "\033[7m", "\033[27m"
	type piece struct {
		esc  bool
		s    string
		at   []int // a plain piece's character offsets (see chars)
		from int   // the index of its first character in the line's text
	}
	return eachLine(r, out, func(b *strings.Builder, line string, nl bool) {
		// Split the line into escapes and the plain text between them; the
		// plain pieces are matched as one text, so a term can span a color
		// change.
		var pieces []piece
		var text []rune
		for s := line; s != ""; {
			if s[0] == '\033' {
				n := max(csiLen(s), 1)
				pieces = append(pieces, piece{esc: true, s: s[:n]})
				s = s[n:]
				continue
			}
			n := strings.IndexByte(s, '\033')
			if n < 0 {
				n = len(s)
			}
			t, at := h.chars(s[:n])
			pieces = append(pieces, piece{s: s[:n], at: at, from: len(text)})
			text = append(text, t...)
			s = s[n:]
		}
		m := h.marks(text)
		in := false
		for _, p := range pieces {
			if p.esc {
				b.WriteString(p.s)
				if in {
					b.WriteString(on)
				}
				continue
			}
			for i := 0; i+1 < len(p.at); i++ {
				if m[p.from+i] != in {
					in = m[p.from+i]
					if in {
						b.WriteString(on)
					} else {
						b.WriteString(off)
					}
				}
				b.WriteString(p.s[p.at[i]:p.at[i+1]])
			}
		}
		if in {
			b.WriteString(off)
		}
		if nl {
			b.WriteString("\n")
		}
	})
}

// csiLen is the length of the CSI sequence (ESC [ params letter, params being
// digits, ';' and '?') that s starts with, or 0 if it starts with none.
func csiLen(s string) int {
	if len(s) < 2 || s[0] != '\033' || s[1] != '[' {
		return 0
	}
	i := 2
	for i < len(s) && (s[i] >= '0' && s[i] <= '9' || s[i] == ';' || s[i] == '?') {
		i++
	}
	if i < len(s) && (s[i] >= 'A' && s[i] <= 'Z' || s[i] >= 'a' && s[i] <= 'z') {
		return i + 1
	}
	return 0
}
