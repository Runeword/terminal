package main

import (
	"strings"
	"testing"
)

// List (rows) and preview (mark) highlight codes.
const (
	hl, rs   = "\033[1;36m", "\033[0m"
	rev, unr = "\033[7m", "\033[27m"
)

// header and match build the rows fm_rg.sh's fzf binding expects.
func header(path, line string) string {
	return "\033[1;35m" + path + "\033[0m\t" + path + "\t" + line + "\tH\n"
}

func match(path, line, code string) string {
	return "  " + line + ":" + code + "\t" + path + "\t" + line + "\tM\n"
}

func TestRows(t *testing.T) {
	tests := []struct {
		name, query, in, want string
	}{
		{
			"one header per file", "'foo",
			"a.go\x001:foo bar\na.go\x002:foo\nb.go\x003:x foo\n",
			header("a.go", "1") + match("a.go", "1", hl+"foo"+rs+" bar") + match("a.go", "2", hl+"foo"+rs) +
				header("b.go", "3") + match("b.go", "3", "x "+hl+"foo"+rs),
		},
		{
			"fuzzy marks the leftmost run", "fb", "a\x001:foo bar",
			header("a", "1") + match("a", "1", hl+"f"+rs+"oo "+hl+"b"+rs+"ar"),
		},
		{"fuzzy marks nothing unless complete", "fz", "a\x001:foo", header("a", "1") + match("a", "1", "foo")},
		{
			"exact marks every occurrence, overlaps too", "'aa", "a\x001:aaa-aa",
			header("a", "1") + match("a", "1", hl+"aaa"+rs+"-"+hl+"aa"+rs),
		},
		{
			"every positive term, none negated", "'foo bar !baz", "a\x001:bar foo baz",
			header("a", "1") + match("a", "1", hl+"bar"+rs+" "+hl+"foo"+rs+" baz"),
		},
		{"lowercase query ignores case", "'foo", "a\x001:FOO", header("a", "1") + match("a", "1", hl+"FOO"+rs)},
		{"lowercase query folds non-ASCII", "'été", "a\x001:Été", header("a", "1") + match("a", "1", hl+"Été"+rs)},
		{"uppercase query keeps case", "'Foo", "a\x001:foo Foo", header("a", "1") + match("a", "1", "foo "+hl+"Foo"+rs)},
		{
			"path split at the NUL; tabs squashed", "'x", "a:b\tc\x007:x\ty",
			header("a:b c", "7") + match("a:b c", "7", hl+"x"+rs+" y"),
		},
		{"a record without NUL is dropped", "'x", "frag\nb\x001:x\n", header("b", "1") + match("b", "1", hl+"x"+rs)},
		{"no line number", "'x", "a\x00x", header("a", "") + match("a", "", hl+"x"+rs)},
		{
			"invalid UTF-8 copied through", "'é", "a\x001:\xff\xe9é",
			header("a", "1") + match("a", "1", "\xff\xe9"+hl+"é"+rs),
		},
		{"no terms: plain rows", "", "a\x001:x", header("a", "1") + match("a", "1", "x")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			if err := rows(strings.NewReader(tt.in), &b, tt.query); err != nil {
				t.Fatal(err)
			}
			if b.String() != tt.want {
				t.Errorf("rows(%q, %q)\n got %q\nwant %q", tt.query, tt.in, b.String(), tt.want)
			}
		})
	}
}

func TestMark(t *testing.T) {
	tests := []struct {
		name, query, in, want string
	}{
		{"no terms copies the input", "!foo", "foo\nbar", "foo\nbar"},
		{"plain text", "'bar", "foo bar\n", "foo " + rev + "bar" + unr + "\n"},
		{"each line on its own", "'o", "o\nxo\n", rev + "o" + unr + "\nx" + rev + "o" + unr + "\n"},
		{
			"colors copied, reverse re-asserted after one", "'foo", "\033[31mfo\033[0mo\n",
			"\033[31m" + rev + "fo\033[0m" + rev + "o" + unr + "\n",
		},
		{"never matched inside an escape", "'31m", "\033[31mx 31m\n", "\033[31mx " + rev + "31m" + unr + "\n"},
		{"a lone ESC is an escape", "'ab", "a\033b\n", rev + "a\033" + rev + "b" + unr + "\n"},
		{"fuzzy across a color change", "fb", "\033[1mfoo\033[0m bar\n", "\033[1m" + rev + "f" + unr + "oo\033[0m " + rev + "b" + unr + "ar\n"},
		{"a missing final newline stays missing", "'foo", "foo", rev + "foo" + unr},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			if err := mark(strings.NewReader(tt.in), &b, tt.query); err != nil {
				t.Fatal(err)
			}
			if b.String() != tt.want {
				t.Errorf("mark(%q, %q)\n got %q\nwant %q", tt.query, tt.in, b.String(), tt.want)
			}
		})
	}
}
