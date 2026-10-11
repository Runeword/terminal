package main

import (
	"strings"
	"testing"
)

// render writes q as "kind:text" terms, | inside a set, & between sets; ! marks
// an exclusion, ~ a term matched without accent folding.
func render(q query) string {
	kinds := [...]string{"fuzzy", "exact", "boundary", "prefix", "suffix", "equal"}
	var sets []string
	for _, set := range q.sets {
		var terms []string
		for _, t := range set {
			s := kinds[t.typ] + ":" + string(t.text)
			if t.inv {
				s = "!" + s
			}
			if !t.norm {
				s = "~" + s
			}
			terms = append(terms, s)
		}
		sets = append(sets, strings.Join(terms, " | "))
	}
	return strings.Join(sets, " & ")
}

func TestParse(t *testing.T) {
	tests := []struct {
		name, query, want string
		fold              bool
	}{
		{"empty", "", "", true},
		{"blanks only", "   ", "", true},
		{"fuzzy", "cfg", "fuzzy:cfg", true},
		{"exact", "'foo", "exact:foo", true},
		{"boundary", "'foo'", "boundary:foo", true},
		{"two quotes are an exact quote", "''", "exact:'", true},
		{"prefix", "^foo", "prefix:foo", true},
		{"suffix", "foo$", "suffix:foo", true},
		{"equal", "^foo$", "equal:foo", true},
		{"lone $ is fuzzy", "$", "fuzzy:$", true},
		{"lone operators are dropped", "^ ! '", "", true},
		{"inverse is exact", "!foo", "!exact:foo", true},
		{"inverse quoted is fuzzy", "!'foo", "!fuzzy:foo", true},
		{"inverse prefix", "!^foo", "!prefix:foo", true},
		{"inverse suffix", "!foo$", "!suffix:foo", true},
		{"inverse boundary", "!'foo'", "!boundary:foo", true},
		{"a quote outranks the suffix, as in fzf", "'foo$", "exact:foo", true},
		{"and", "foo bar", "fuzzy:foo & fuzzy:bar", true},
		{"or binds tighter than and", "foo bar | baz", "fuzzy:foo & fuzzy:bar | fuzzy:baz", true},
		{"a leading bar is a term", "| foo", "fuzzy:| & fuzzy:foo", true},
		{"a bar after a bar is a term", "foo | | bar", "fuzzy:foo | fuzzy:| & fuzzy:bar", true},
		{"escaped space", `foo\ bar`, "fuzzy:foo bar", true},
		{"escaped trailing space kept", `foo\ `, "fuzzy:foo ", true},
		{"surrounding blanks trimmed", "  foo  ", "fuzzy:foo", true},
		{"ASCII uppercase makes it all case-sensitive", "Foo bar", "fuzzy:Foo & fuzzy:bar", false},
		{"non-ASCII uppercase folds", "Été", "~fuzzy:été", true},
		{"a typed accent turns folding off", "café cafe", "~fuzzy:café & fuzzy:cafe", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			q := parse(tt.query)
			if got := render(q); got != tt.want {
				t.Errorf("parse(%q) = %q, want %q", tt.query, got, tt.want)
			}
			if q.fold != tt.fold {
				t.Errorf("parse(%q).fold = %v, want %v", tt.query, q.fold, tt.fold)
			}
		})
	}
}

func TestAccepts(t *testing.T) {
	tests := []struct {
		name, query, line string
		want              bool
	}{
		{"fuzzy in order", "cfg", "config", true},
		{"fuzzy out of order", "cfg", "gfc", false},
		{"exact", "'onf", "config", true},
		{"exact is contiguous", "'cfg", "config", false},
		{"boundary on both sides", "'foo'", "a foo b", true},
		{"an underscore is a boundary", "'foo'", "foo_bar", true},
		{"boundary not inside a word", "'foo'", "foobar afoo", false},
		{"prefix past leading blanks", "^ret", "\t  return x", true},
		{"prefix at the start only", "^ret", "x return", false},
		{"suffix before trailing blanks", "x$", "return x \t", true},
		{"suffix at the end only", "x$", "x return", false},
		{"equal ignores surrounding blanks", "^foo$", "  foo  ", true},
		{"equal is the whole line", "^foo$", "foo bar", false},
		{"exclusion", "foo !bar", "foo bar", false},
		{"exclusion absent", "foo !bar", "foo baz", true},
		{"fuzzy exclusion", "foo !'bz", "foo baz", false},
		{"or", "go$ | rb$", "x.rb", true},
		{"or, neither", "go$ | rb$", "x.py", false},
		{"or with an exclusion", "foo | !bar", "baz", true},
		{"or with an exclusion, both fail", "foo | !bar", "bar", false},
		{"lowercase query ignores case", "'foo", "FOO", true},
		{"uppercase term keeps case", "'Foo", "foo", false},
		{"case is decided for the whole query", "Foo bar", "Foo BAR", false},
		{"non-ASCII case folds", "'été", "ÉTÉ", true},
		{"dotted capital I lower-cases to i, as in fzf", "'istanbul", "İstanbul", true},
		{"Kelvin sign lower-cases to k", "'k", "K", true},
		{"accents fold", "cafe", "CAFÉ", true},
		{"a typed accent must be there", "'café", "cafe", false},
		{"a term after a Latin-1 byte", "'foo", "caf\xe9 au lait: foo", true},
		{"fuzzy across a Latin-1 byte", "cl", "c\xe9l", true},
		{"escaped space", `foo\ bar`, "foo bar", true},
		{"escaped space is a character", `foo\ bar`, "foobar", false},
		{"empty query", "", "x", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var l line
			l.reset(tt.line)
			if got := parse(tt.query).accepts(&l); got != tt.want {
				t.Errorf("parse(%q).accepts(%q) = %v, want %v", tt.query, tt.line, got, tt.want)
			}
		})
	}
}

// CJK characters have no case or accent forms, so their regexes are plain.
func TestPrefilter(t *testing.T) {
	tests := []struct {
		name, query, want string
		ok                bool
	}{
		{"empty", "", "", false},
		{"exclusions only", "!文", "", false},
		{"exact", "'中文", "中文", true},
		{"fuzzy steps over any byte but a newline", "中文", `中(?-u:[^\n])*?文`, true},
		{"anchors are dropped", "^中$", "中", true},
		{"an or set alternates", "中 | 文", "中|文", true},
		{"exclusions are left to rows", "中 !文", "中", true},
		{"no set free of exclusions", "!文 | 中", "^", true},
		{"a literal outweighs a fuzzy term", "'文' 中", "文", true},
		{"metacharacters escaped", "'中.", `中[\.．｡]`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := parse(tt.query).prefilter()
			if got != tt.want || ok != tt.ok {
				t.Errorf("parse(%q).prefilter() = %q, %v, want %q, %v", tt.query, got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestClass(t *testing.T) {
	tests := []struct {
		name       string
		r          rune
		fold, norm bool
		has, lacks string
	}{
		{"folded i takes İ, which rg's -i misses", 'i', true, false, "iIİ", "Ì"},
		{"normalized e takes its accents", 'e', true, true, "eEéÉè", ""},
		{"a typed accent folds case only", 'é', true, false, "éÉ", "e"},
		{"case-sensitive and unnormalized: itself", 'é', false, false, "é", "É"},
		{"case-sensitive A takes accented capitals", 'A', false, true, "AÀ", "a"},
		{"punctuation escaped in the class", '-', true, true, `\-`, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := query{fold: tt.fold}.class(tt.r, tt.norm)
			for _, c := range tt.has {
				if !strings.ContainsRune(got, c) {
					t.Errorf("class(%q) = %q, lacks %q", tt.r, got, c)
				}
			}
			for _, c := range tt.lacks {
				if strings.ContainsRune(got, c) {
					t.Errorf("class(%q) = %q, has %q", tt.r, got, c)
				}
			}
		})
	}
}
