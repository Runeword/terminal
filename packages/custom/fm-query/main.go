// Command fm-query compiles an fzf-style extended-search query into a PCRE2
// filter pattern (for `rg -P`) and a tab-separated highlight spec, printed as
// two lines on stdout: the pattern, then the spec. It is the single parser
// shared by fm_rg.sh (pattern -> rg, spec -> its highlight awk) and
// fm_preview.sh (spec -> preview highlight terms), so the two scripts can no
// longer drift.
//
// Query grammar (fzf-compatible): whitespace separates AND terms; a bare term
// is fuzzy ("cfg" matches "config"); 'term is an exact substring; ^term / term$
// anchor to line start/end; !term excludes; a lone | ORs the terms on either
// side of it; a backslash escapes a space, so "foo\ bar" is one term with a
// literal space. Each AND term (or |-joined OR group) becomes a lookahead so
// they combine on one line. A query with no positive term (empty, or only
// exclusions) compiles to an empty pattern, which the caller treats as "no
// results" rather than dumping the whole tree. Smart-case is decided by the
// caller from the raw query, not here.
package main

import (
	"fmt"
	"os"
	"strings"
)

// meta is the set of PCRE metacharacters escape and fuzzy backslash-escape.
const meta = ".^$*+?()[]{}|\\"

// sen stands in for a backslash-escaped space while the query is split on
// whitespace, so "foo\ bar" survives as one token. It is a byte an fzf query
// cannot contain.
const sen = "\x01"

// escape backslash-escapes every regex metacharacter in s, turning it into a
// literal-match fragment.
func escape(s string) string {
	var b strings.Builder
	for _, c := range s {
		if strings.ContainsRune(meta, c) {
			b.WriteByte('\\')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// fuzzy turns s into a fuzzy PCRE fragment: its characters in order, each
// escaped, joined by ".*?" (fzf-style, so "cfg" matches "config").
func fuzzy(s string) string {
	var b strings.Builder
	first := true
	for _, c := range s {
		if !first {
			b.WriteString(".*?")
		}
		if strings.ContainsRune(meta, c) {
			b.WriteByte('\\')
		}
		b.WriteRune(c)
		first = false
	}
	return b.String()
}

// group is one accumulated term's lookahead body plus whether it is negated.
// Terms buffer here so a run joined by "|" can be emitted as one alternation.
type group struct {
	body string
	neg  bool
}

// compile turns an fzf-style query into a PCRE2 pattern and a tab-separated
// highlight spec ("L:text" exact, "F:text" fuzzy; positive terms only). It
// returns "", "" when the query has no positive term.
func compile(query string) (pattern, spec string) {
	q := strings.ReplaceAll(query, `\ `, sen)
	tokens := strings.FieldsFunc(q, func(r rune) bool {
		return r == ' ' || r == '\t'
	})

	var look strings.Builder
	var specParts []string
	var grp []group
	pos := false
	orNext := false

	// flush emits the buffered group as a single lookahead: a lone term keeps
	// the plain (?=b)/(?!b) form; a |-joined group alternates the bodies inside
	// one (?=b1|b2|...) (negated members become nested (?!b) branches).
	flush := func() {
		if len(grp) == 0 {
			return
		}
		if len(grp) == 1 {
			if grp[0].neg {
				look.WriteString("(?!" + grp[0].body + ")")
			} else {
				look.WriteString("(?=" + grp[0].body + ")")
			}
			grp = grp[:0]
			return
		}
		var alts []string
		for _, g := range grp {
			if g.neg {
				alts = append(alts, "(?!"+g.body+")")
			} else {
				alts = append(alts, g.body)
			}
		}
		look.WriteString("(?=" + strings.Join(alts, "|") + ")")
		grp = grp[:0]
	}

	for _, w := range tokens {
		if w == "|" {
			orNext = true
			continue
		}

		neg := false
		if strings.HasPrefix(w, "!") {
			neg = true
			w = w[1:]
		}
		pre, suf, ex := false, false, false
		if w != "" {
			if strings.HasPrefix(w, "'") {
				ex = true
				w = w[1:]
			} else {
				if strings.HasPrefix(w, "^") {
					pre = true
					w = w[1:]
				}
				if w != "" && strings.HasSuffix(w, "$") {
					suf = true
					w = w[:len(w)-1]
				}
			}
		}
		if w == "" {
			continue
		}
		w = strings.ReplaceAll(w, sen, " ")

		if !orNext && len(grp) > 0 {
			flush()
		}
		orNext = false

		core := fuzzy(w)
		if ex || pre || suf || neg {
			core = escape(w)
		}
		var body string
		switch {
		case pre && suf:
			body = core + "$"
		case pre:
			body = core
		case suf:
			body = ".*" + core + "$"
		default:
			body = ".*" + core
		}
		grp = append(grp, group{body: body, neg: neg})

		if !neg {
			pos = true
			kind := "F:"
			if ex || pre || suf {
				kind = "L:"
			}
			specParts = append(specParts, kind+w)
		}
	}
	flush()

	if !pos {
		return "", ""
	}
	return "^" + look.String(), strings.Join(specParts, "\t")
}

func main() {
	query := ""
	if len(os.Args) > 1 {
		query = os.Args[1]
	}
	pattern, spec := compile(query)
	fmt.Println(pattern)
	fmt.Println(spec)
}
