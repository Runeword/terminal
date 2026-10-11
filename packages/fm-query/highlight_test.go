package main

import (
	"strings"
	"testing"
	"time"
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

// runRows runs rows with sorting bounded by count only, so timing can't change
// the order.
func runRows(t *testing.T, query, in string) string {
	t.Helper()
	defer func(w time.Duration) { sortWait = w }(sortWait)
	sortWait = time.Hour
	var b strings.Builder
	if err := rows(strings.NewReader(in), &b, query); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func TestRows(t *testing.T) {
	long := strings.Repeat("a", 100) + "needle" + strings.Repeat("b", 500)
	tests := []struct {
		name, query, in, want string
	}{
		{
			"one header per file", "'foo",
			"a.go\x001:foo bar\na.go\x002:foo\nb.go\x003:x foo\n",
			header("a.go", "1") + match("a.go", "1", hl+"foo"+rs+" bar") + match("a.go", "2", hl+"foo"+rs) +
				header("b.go", "3") + match("b.go", "3", "x "+hl+"foo"+rs),
		},
		{"only matching lines", "'foo !bar", "a\x001:foo\na\x002:foo bar\n", header("a", "1") + match("a", "1", hl+"foo"+rs)},
		{"no header without a matching line", "'foo", "a\x001:nope\nb\x002:foo\n", header("b", "2") + match("b", "2", hl+"foo"+rs)},
		{
			"fuzzy marks the shortest run, as fzf's v1", "func", "a\x001:f.Close() // flush, then func ok",
			header("a", "1") + match("a", "1", "f.Close() // flush, then "+hl+"func"+rs+" ok"),
		},
		{"fuzzy across a line", "fb", "a\x001:foo bar", header("a", "1") + match("a", "1", hl+"f"+rs+"oo "+hl+"b"+rs+"ar")},
		{
			"exact marks every occurrence, overlaps too", "'aa", "a\x001:aaa-aa",
			header("a", "1") + match("a", "1", hl+"aaa"+rs+"-"+hl+"aa"+rs),
		},
		{"prefix marks the anchored span only", "^foo", "a\x001:  foo = foo", header("a", "1") + match("a", "1", "  "+hl+"foo"+rs+" = foo")},
		{"suffix before trailing blanks", "x$", "a\x001:a x  ", header("a", "1") + match("a", "1", "a "+hl+"x"+rs+"  ")},
		{"boundary marks whole words only", "'foo'", "a\x001:foobar foo_bar", header("a", "1") + match("a", "1", "foobar "+hl+"foo"+rs+"_bar")},
		{"lowercase query ignores case", "'foo", "a\x001:FOO", header("a", "1") + match("a", "1", hl+"FOO"+rs)},
		{"lowercase query folds non-ASCII", "'été", "a\x001:Été", header("a", "1") + match("a", "1", hl+"Été"+rs)},
		{"uppercase query keeps case", "'Foo", "a\x001:foo Foo", header("a", "1") + match("a", "1", "foo "+hl+"Foo"+rs)},
		{"accents fold unless typed", "cafe", "a\x001:café", header("a", "1") + match("a", "1", hl+"café"+rs)},
		{"a path with a tab or a control character is dropped", "'x", "a\tb\x001:x\nc\x1bd\x002:x\ne\x003:x\n", header("e", "3") + match("e", "3", hl+"x"+rs)},
		{"a path with invalid UTF-8 is dropped", "'x", "\xff\x001:x\n", ""},
		{"a record without NUL is dropped", "'x", "frag\nb\x001:x\n", header("b", "1") + match("b", "1", hl+"x"+rs)},
		{"control characters shown as symbols", "'x", "a\x001:x\x1b[31m\ty\x7f", header("a", "1") + match("a", "1", hl+"x"+rs+"␛[31m y␡")},
		{"a trailing CR goes", "x$", "a\x001:a x\r", header("a", "1") + match("a", "1", "a "+hl+"x"+rs)},
		{"a term after a Latin-1 byte", "'foo", "a\x001:caf\xe9 foo", header("a", "1") + match("a", "1", "caf� "+hl+"foo"+rs)},
		{
			"a long line is shown around its first mark", "'needle", "a\x001:" + long,
			header("a", "1") + match("a", "1", "…"+strings.Repeat("a", winLead)+hl+"needle"+rs+strings.Repeat("b", winMax-winLead-6)+"…"),
		},
		{"no line number", "'x", "a\x00x", header("a", "") + match("a", "", hl+"x"+rs)},
		{"no positive term: nothing", "!x", "a\x001:y", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := runRows(t, tt.query, tt.in); got != tt.want {
				t.Errorf("rows(%q, %q)\n got %q\nwant %q", tt.query, tt.in, got, tt.want)
			}
		})
	}
}

func TestRowsOrder(t *testing.T) {
	in := "b\x001:x\nb\x002:x\na\x003:x\n"
	byPath := header("a", "3") + match("a", "3", hl+"x"+rs) +
		header("b", "1") + match("b", "1", hl+"x"+rs) + match("b", "2", hl+"x"+rs)
	asRead := header("b", "1") + match("b", "1", hl+"x"+rs) + match("b", "2", hl+"x"+rs) +
		header("a", "3") + match("a", "3", hl+"x"+rs)
	tests := []struct {
		name string
		max  int
		want string
	}{
		{"a small search is listed by path", 10, byPath},
		{"past sortMax, rows stream as read", 1, asRead},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			defer func(m int) { sortMax = m }(sortMax)
			sortMax = tt.max
			if got := runRows(t, "'x", in); got != tt.want {
				t.Errorf("rows\n got %q\nwant %q", got, tt.want)
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
		{"colon parameters stay in the escape", "'38", "\033[38:2::1:2:3mx 38\n", "\033[38:2::1:2:3mx " + rev + "38" + unr + "\n"},
		{"a charset designation is an escape", "'b", "\033(Bab\n", "\033(Ba" + rev + "b" + unr + "\n"},
		{"a two-byte escape is not text", "'ab", "a\033b\n", "a\033b\n"},
		{
			"a hyperlink is copied whole", "'x", "\033]8;;http://x\033\\x\033]8;;\033\\\n",
			"\033]8;;http://x\033\\" + rev + "x\033]8;;\033\\" + rev + unr + "\n",
		},
		{"fuzzy across a color change", "fb", "\033[1mfoo\033[0m bar\n", "\033[1m" + rev + "f" + unr + "oo\033[0m " + rev + "b" + unr + "ar\n"},
		{"prefix marks the anchored span only", "^foo", "  foo foo\n", "  " + rev + "foo" + unr + " foo\n"},
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

func TestEscLen(t *testing.T) {
	tests := []struct {
		name, in string
		want     int
	}{
		{"lone ESC", "\033", 1},
		{"SGR", "\033[1;31mx", 7},
		{"colon parameters", "\033[38:2::1:2:3mx", 14},
		{"private marker", "\033[?2004hx", 8},
		{"intermediate byte", "\033[1 qx", 5},
		{"malformed CSI", "\033[1\x01", 1},
		{"OSC up to BEL", "\033]0;title\x07x", 10},
		{"OSC up to ST", "\033]8;;u\033\\x", 8},
		{"unterminated string", "\033]8;;u", 6},
		{"DCS", "\033Pq#0\033\\x", 7},
		{"charset designation", "\033(Bx", 3},
		{"two-byte escape", "\033cx", 2},
		{"ESC before a control", "\033\x01", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := escLen(tt.in); got != tt.want {
				t.Errorf("escLen(%q) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}
