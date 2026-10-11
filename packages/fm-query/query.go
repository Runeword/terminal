package main

// The query: parsed, matched and turned into rg's prefilter exactly as fzf
// 0.74 parses and matches its extended-search syntax (src/pattern.go,
// src/algo/algo.go), but for case, decided once for the whole query.

import (
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// termType is one of fzf's term kinds.
type termType int

const (
	termFuzzy    termType = iota // foo: its characters in order
	termExact                    // 'foo: a substring
	termBoundary                 // 'foo': a substring on word boundaries
	termPrefix                   // ^foo: the line's start, past leading whitespace
	termSuffix                   // foo$: the line's end, before trailing whitespace
	termEqual                    // ^foo$: the whole line, surrounding whitespace aside
)

// term is one query term. Its text is folded the way the line's characters
// are compared: lower-cased unless the query is case-sensitive, and with
// accents removed when norm is set.
type term struct {
	typ  termType
	inv  bool
	norm bool
	text []rune
}

// query is a parsed query: a line matches when every set does, and a set when
// any of its terms does (a lone | joins the terms on either side into a set).
type query struct {
	sets [][]term
	fold bool
}

// parse reads s as fzf's parseTerms does. Unlike fzf, which decides case per
// term, any ASCII uppercase letter makes the whole query case-sensitive.
func parse(s string) query {
	q := query{fold: !strings.ContainsAny(s, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")}
	s = strings.TrimLeft(s, " ")
	for strings.HasSuffix(s, " ") && !strings.HasSuffix(s, `\ `) {
		s = s[:len(s)-1]
	}
	s = strings.ReplaceAll(s, `\ `, "\t")
	var set []term
	switchSet, afterBar := false, false
	for _, tok := range strings.FieldsFunc(s, func(r rune) bool { return r == ' ' }) {
		text := strings.ReplaceAll(tok, "\t", " ")
		lower := strings.ToLower(text)
		if q.fold {
			text = lower
		}
		if len(set) > 0 && !afterBar && text == "|" {
			switchSet, afterBar = false, true
			continue
		}
		afterBar = false

		// A term with an accented letter of its own is matched as typed.
		t := term{typ: termFuzzy, norm: lower == string(normalizeRunes([]rune(lower)))}
		if strings.HasPrefix(text, "!") {
			t.inv, t.typ, text = true, termExact, text[1:]
		}
		if text != "$" && strings.HasSuffix(text, "$") {
			t.typ, text = termSuffix, text[:len(text)-1]
		}
		switch {
		case len(text) > 2 && strings.HasPrefix(text, "'") && strings.HasSuffix(text, "'"):
			t.typ, text = termBoundary, text[1:len(text)-1]
		case strings.HasPrefix(text, "'"):
			// ' flips exactness: !'foo excludes fuzzily.
			if t.inv {
				t.typ = termFuzzy
			} else {
				t.typ = termExact
			}
			text = text[1:]
		case strings.HasPrefix(text, "^"):
			if t.typ == termSuffix {
				t.typ = termEqual
			} else {
				t.typ = termPrefix
			}
			text = text[1:]
		}
		if text == "" {
			continue
		}
		if switchSet {
			q.sets = append(q.sets, set)
			set = nil
		}
		t.text = []rune(text)
		if t.norm {
			t.text = normalizeRunes(t.text)
		}
		set = append(set, t)
		switchSet = true
	}
	if len(set) > 0 {
		q.sets = append(q.sets, set)
	}
	return q
}

// positive reports whether the query has a term that is not an exclusion: a
// query without one (empty, or exclusions only) lists nothing rather than
// every line of the tree.
func (q query) positive() bool {
	for _, set := range q.sets {
		for _, t := range set {
			if !t.inv {
				return true
			}
		}
	}
	return false
}

func normalizeRunes(rs []rune) []rune {
	out := make([]rune, len(rs))
	for i, r := range rs {
		out[i] = normalizeRune(r)
	}
	return out
}

// foldRune folds a line's character the way the terms' text is folded.
func (q query) foldRune(r rune, norm bool) rune {
	if q.fold {
		if r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		} else if r > unicode.MaxASCII {
			r = unicode.ToLower(r)
		}
	}
	if norm {
		r = normalizeRune(r)
	}
	return r
}

// line is one line of text, split into characters (an invalid UTF-8 byte is
// one U+FFFD) with each one's byte offset, plus len(s), so s[at[i]:at[i+1]] is
// character i verbatim. Its folded forms are built on first use.
type line struct {
	s      string
	raw    []rune
	at     []int
	folded [2][]rune // indexed by norm
	ready  [2]bool
}

// reset makes l hold s, reusing l's buffers.
func (l *line) reset(s string) {
	l.begin()
	l.add(s, 0)
	l.s = s
	l.end()
}

// begin empties l, to be built piece by piece with add, then closed with end
// once l.s holds the pieces.
func (l *line) begin() {
	l.s, l.raw, l.at, l.ready = "", l.raw[:0], l.at[:0], [2]bool{}
}

// add appends the characters of s, which sits at byte offset off of l.s.
func (l *line) add(s string, off int) {
	for i := 0; i < len(s); {
		r, size := rune(s[i]), 1
		if r >= utf8.RuneSelf {
			r, size = utf8.DecodeRuneInString(s[i:])
		}
		l.raw = append(l.raw, r)
		l.at = append(l.at, off+i)
		i += size
	}
}

// end closes the offsets: at[len(raw)] is len(l.s).
func (l *line) end() {
	l.at = append(l.at, len(l.s))
}

func (l *line) fold(q query, norm bool) []rune {
	k := 0
	if norm {
		k = 1
	}
	if !l.ready[k] {
		f := l.folded[k][:0]
		for _, r := range l.raw {
			f = append(f, q.foldRune(r, norm))
		}
		l.folded[k], l.ready[k] = f, true
	}
	return l.folded[k]
}

// accepts reports whether the line matches the query.
func (q query) accepts(l *line) bool {
	for _, set := range q.sets {
		ok := false
		for _, t := range set {
			if t.find(q, l, nil) != t.inv {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return len(q.sets) > 0
}

// mark sets m (one flag per character of l) where the query's positive
// terms are found, as fzf highlights them: the shortest run of a fuzzy term,
// the anchored span of the others -- and, unlike fzf, every occurrence of an
// exact term rather than its best one.
func (q query) mark(l *line, m []bool) {
	for _, set := range q.sets {
		for _, t := range set {
			if !t.inv {
				t.find(q, l, m)
			}
		}
	}
}

// find reports whether t occurs in l, marking its characters in m when m is
// not nil.
func (t term) find(q query, l *line, m []bool) bool {
	f, p, raw := l.fold(q, t.norm), t.text, l.raw
	switch t.typ {
	case termFuzzy:
		// fzf's v1: the leftmost end, then back to the latest start, so
		// "func" marks the word rather than letters strewn before it.
		pi, end := 0, -1
		for i, c := range f {
			if c == p[pi] {
				if pi++; pi == len(p) {
					end = i
					break
				}
			}
		}
		if end < 0 {
			return false
		}
		if m != nil {
			start := end
			for i, pj := end, len(p)-1; i >= 0; i-- {
				if f[i] == p[pj] {
					if pj--; pj < 0 {
						start = i
						break
					}
				}
			}
			for i, pj := start, 0; i <= end && pj < len(p); i++ {
				if f[i] == p[pj] {
					m[i] = true
					pj++
				}
			}
		}
		return true
	case termExact, termBoundary:
		found := false
		for i := 0; i+len(p) <= len(f); i++ {
			if !equalRunes(f[i:i+len(p)], p) ||
				t.typ == termBoundary && (!boundary(raw, i-1) || !boundary(raw, i+len(p))) {
				continue
			}
			if m == nil {
				return true
			}
			found = true
			for j := i; j < i+len(p); j++ {
				m[j] = true
			}
		}
		return found
	}
	// Anchored: fzf skips the line's surrounding whitespace unless the term
	// itself starts (or ends) with some.
	start, end := 0, len(raw)
	if t.typ != termSuffix && !unicode.IsSpace(p[0]) {
		for start < len(raw) && unicode.IsSpace(raw[start]) {
			start++
		}
	}
	if t.typ != termPrefix && !unicode.IsSpace(p[len(p)-1]) {
		for end > 0 && unicode.IsSpace(raw[end-1]) {
			end--
		}
	}
	switch t.typ {
	case termPrefix:
		end = start + len(p)
	case termSuffix:
		start = end - len(p)
	}
	if start < 0 || end > len(f) || end-start != len(p) || !equalRunes(f[start:end], p) {
		return false
	}
	for i := start; m != nil && i < end; i++ {
		m[i] = true
	}
	return true
}

// boundary reports whether character i of raw is outside a word: before the
// line, past it, or neither a letter nor a digit (fzf's char classes up to
// charDelimiter).
func boundary(raw []rune, i int) bool {
	return i < 0 || i >= len(raw) || !unicode.IsLetter(raw[i]) && !unicode.IsNumber(raw[i])
}

func equalRunes(a, b []rune) bool {
	for i := range b {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// prefilter returns a regex for rg's default engine that every matching line
// matches -- one set of positive terms, the most selective -- so rg narrows
// the search in linear time and rows applies the whole query. ok is false for
// a query without a positive term; "^" (every line) is returned when no set
// is free of exclusions. rg runs it case-insensitively: rows decides case.
func (q query) prefilter() (re string, ok bool) {
	if !q.positive() {
		return "", false
	}
	var best []term
	bestScore := 0
	for _, set := range q.sets {
		score := -1
		for _, t := range set {
			if t.inv {
				score = -1
				break
			}
			w := len(t.text)
			if t.typ != termFuzzy {
				w *= 2
			}
			if score < 0 || w < score {
				score = w
			}
		}
		if score > bestScore {
			best, bestScore = set, score
		}
	}
	if best == nil {
		return "^", true
	}
	alts := make([]string, len(best))
	for i, t := range best {
		var b strings.Builder
		for j, r := range t.text {
			if j > 0 && t.typ == termFuzzy {
				// Any byte but a newline, so an invalid UTF-8 byte (a
				// Latin-1 letter) can't hide the rest of the line.
				b.WriteString(`(?-u:[^\n])*?`)
			}
			b.WriteString(q.class(r, t.norm))
		}
		alts[i] = b.String()
	}
	return strings.Join(alts, "|"), true
}

// class is a regex for every character that folds to r: r itself, the
// letters lower-casing to it (rg's own case folding misses some, such as İ
// for i) and the accented letters normalizing to it.
func (q query) class(r rune, norm bool) string {
	set := []rune{r}
	for _, c := range foldable() {
		if c != r && q.foldRune(c, norm) == r {
			set = append(set, c)
		}
	}
	if len(set) == 1 {
		return regexRune(r)
	}
	var b strings.Builder
	b.WriteByte('[')
	for _, c := range set {
		b.WriteString(regexRune(c))
	}
	b.WriteByte(']')
	return b.String()
}

// regexRune escapes r for rg's regex syntax, in or out of a class.
func regexRune(r rune) string {
	if strings.ContainsRune(`\.+*?()|[]{}^$#&-~`, r) {
		return `\` + string(r)
	}
	return string(r)
}

// foldable lists the characters folding can change: those with a lower-case
// mapping and those fzf normalizes, sorted.
var foldable = sync.OnceValue(func() []rune {
	seen := map[rune]bool{}
	for _, cr := range unicode.CaseRanges {
		for c := rune(cr.Lo); c <= rune(cr.Hi); c++ {
			if unicode.ToLower(c) != c {
				seen[c] = true
			}
		}
	}
	for c := range normalized {
		seen[c] = true
	}
	rs := make([]rune, 0, len(seen))
	for c := range seen {
		rs = append(rs, c)
	}
	sort.Slice(rs, func(i, j int) bool { return rs[i] < rs[j] })
	return rs
})
