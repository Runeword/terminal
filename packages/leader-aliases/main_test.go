package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sample exercises every mode, a submenu, the space chord, tab and two-space
// separators, a command with quotes and pipes, and groups whose file order
// differs from their sorted order.
const sample = `# leader table
[open]
oh  run  history  nvim $HISTFILE

[git]
gt	run	file › list	git status
gbs  eval  branch › switch  __git_branch_switch
gbc   edit   branch › new   git switch --create <branch>
gdp  eval-edit  patch  __git_patch
gc  run  commit  git commit
# the amend line belongs to the same submenu
gc  edit  amend  git commit --amend
gf  run  log  git log --format="%h" | jq '.'

[zoxide]
<space>  run  jump  __zoxide_zi
`

func TestParseKeepsFileOrderAndModes(t *testing.T) {
	rows, _, err := parse("t", sample)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct{ chord, group, cmd, desc, mode string }{
		{"oh", "open", "nvim $HISTFILE", "history", "run"},
		{"gt", "git", "git status", "file › list", "run"},
		{"gbs", "git", "__git_branch_switch", "branch › switch", "eval-run"},
		{"gbc", "git", "git switch --create <branch>", "branch › new", "insert"},
		{"gdp", "git", "__git_patch", "patch", "eval-insert"},
		{"gc", "git", "git commit", "commit", "run"},
		{"gc", "git", "git commit --amend", "amend", "insert"},
		{"gf", "git", `git log --format="%h" | jq '.'`, "log", "run"},
		{" ", "zoxide", "__zoxide_zi", "jump", "run"},
	}
	if len(rows) != len(want) {
		t.Fatalf("got %d rows, want %d: %+v", len(rows), len(want), rows)
	}
	for i, w := range want {
		r := rows[i]
		if r.chord != w.chord || r.group != w.group || r.cmd != w.cmd || r.desc != w.desc || r.mode() != w.mode {
			t.Errorf("row %d: got %q/%q/%q/%q/%s, want %+v", i, r.chord, r.group, r.cmd, r.desc, r.mode(), w)
		}
	}
}

func TestParseSplitsCells(t *testing.T) {
	tests := []struct{ name, line, desc, cmd string }{
		{"single spaces stay in the description", "gx  run  stash › delete all  git stash clear", "stash › delete all", "git stash clear"},
		{"the command is the rest of the line", "gx  run  print  printf '%s  %s\\t' a  b", "print", "printf '%s  %s\\t' a  b"},
		{"a tab alone separates", "gx\trun\tx y\tgit status", "x y", "git status"},
		{"padding before a tab is one separator", "gx   \trun  \tx y     \tgit status", "x y", "git status"},
		{"surrounding blanks are trimmed", "  gx  run  x  git status  \r", "x", "git status"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rows, _, err := parse("t", "[g]\n"+tc.line+"\n")
			if err != nil {
				t.Fatal(err)
			}
			if rows[0].chord != "gx" || rows[0].desc != tc.desc || rows[0].cmd != tc.cmd {
				t.Fatalf("got %q/%q/%q, want gx/%q/%q", rows[0].chord, rows[0].desc, rows[0].cmd, tc.desc, tc.cmd)
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	tests := []struct{ name, src, want string }{
		{"chord before any group", "gt  run  x  git status\n", "t:1: a chord line before any [group] line"},
		{"missing command", "[git]\ngt  run  git status\n", "t:2: expected four columns"},
		{"single spaces only", "[git]\ngt run status git status\n", "t:2: expected four columns"},
		{"unknown mode", "[git]\n\ngt  rnu  status  git status\n", `t:3: unknown mode "rnu" (expected run, edit, eval or eval-edit)`},
		{"chord with a space", "[git]\ng t  run  x  git status\n", `t:2: chord "g t" holds a space: write <space> for the space key`},
		{"chord in two groups", "[git]\ngc  run  a  a\n[gcloud]\ngc  run  b  b\n", `t:4: chord "gc" is already in [git] (line 2); a submenu is adjacent lines of one chord`},
		{"submenu split apart", "[git]\ngc  run  a  a\ngt  run  b  b\ngc  run  c  c\n", `t:4: chord "gc" is already on line 2; the lines of a submenu must be adjacent`},
		{"group twice", "[git]\n[nix]\n[git]\n", "t:3: [git] is already on line 1"},
		{"unclosed group", "[git\n", "t:1: a group line is [name] alone"},
		{"text after a group", "[git] x\n", "t:1: a group line is [name] alone"},
		{"empty group", "[ ]\n", "t:1: empty group name"},
		{"separator in a description", "[git]\ngt  run  x y  git status\n", "t:2: a description must not contain"},
		{"separator in a command", "[git]\ngt  run  x  git status\n", "t:2: a command must not contain"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := parse("t", tc.src)
			if err == nil {
				t.Fatalf("expected an error containing %q", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err, tc.want)
			}
		})
	}
}

func TestFormatAlignsEachRunOfChords(t *testing.T) {
	src := "# c\n[git]\ngt  run  x  git status\n" +
		"gbs  eval  branch › switch\t__git_branch_switch  -a  b\n" +
		"\n" +
		"gx  edit  y  git absorb\n" +
		"[zoxide]\n" +
		"<space>  run  jump  __zoxide_zi\n"
	_, lines, err := parse("t", src)
	if err != nil {
		t.Fatal(err)
	}
	want := "# c\n[git]\n" +
		"gt  \trun  \tx               \tgit status\n" +
		"gbs \teval \tbranch › switch \t__git_branch_switch  -a  b\n" +
		"\n" +
		"gx \tedit \ty \tgit absorb\n" +
		"[zoxide]\n" +
		"<space> \trun \tjump \t__zoxide_zi\n"
	got := format(lines)
	if got != want {
		t.Fatalf("format:\n got %q\nwant %q", got, want)
	}
	// Formatting is stable and reads back to the same rows.
	before, _, _ := parse("t", src)
	after, again, err := parse("t", got)
	if err != nil {
		t.Fatal(err)
	}
	if format(again) != got {
		t.Error("formatting the formatted table changes it")
	}
	if len(after) != len(before) {
		t.Fatalf("formatted table has %d rows, want %d", len(after), len(before))
	}
	for i := range before {
		if after[i] != before[i] {
			t.Errorf("row %d: formatted %+v, want %+v", i, after[i], before[i])
		}
	}
}

func TestFormattedColumnsLineUpAtAnyTabWidth(t *testing.T) {
	_, lines, err := parse("t", sample)
	if err != nil {
		t.Fatal(err)
	}
	text := format(lines)
	for _, width := range []int{1, 2, 4, 8} {
		// In each run of chord lines, every command starts at the same cell.
		start := -1
		for _, l := range strings.Split(text, "\n") {
			if !strings.Contains(l, "\t") {
				start = -1
				continue
			}
			parts := strings.Split(expand(l, width), "")
			col := len(parts) - len([]rune(l[strings.LastIndex(l, "\t")+1:]))
			if start >= 0 && col != start {
				t.Errorf("tab width %d: %q starts its command at %d, not %d", width, l, col, start)
			}
			start = col
		}
	}
}

// expand replaces each tab in s with the spaces that reach the next multiple
// of width, as a terminal or editor shows it.
func expand(s string, width int) string {
	var b strings.Builder
	col := 0
	for _, r := range s {
		if r == '\t' {
			n := width - col%width
			b.WriteString(strings.Repeat(" ", n))
			col += n
			continue
		}
		b.WriteRune(r)
		col++
	}
	return b.String()
}

func TestFormatFileRewritesInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "leader.conf")
	if err := os.WriteFile(path, []byte("[git]\ngt  run  x  git status"), 0o644); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := formatFile(path); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Error("formatting replaced the file instead of rewriting it")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if want := "[git]\ngt \trun \tx \tgit status\n"; string(got) != want {
		t.Errorf("got %q, want %q", got, want)
	}
	// A broken table is reported with its line and left as it was.
	broken := "[git]\ngt  rnu  x  git status\n"
	if err := os.WriteFile(path, []byte(broken), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := formatFile(path); err == nil || !strings.Contains(err.Error(), path+":2: unknown mode") {
		t.Errorf("got error %v, want %s:2: unknown mode", err, path)
	}
	if got, _ := os.ReadFile(path); string(got) != broken {
		t.Errorf("a broken table was rewritten: %q", got)
	}
}

func TestRenderPadsDisplayColumnsAndHidesDispatch(t *testing.T) {
	rows, _, err := parse("t", sample)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := render(&buf, rows, 0); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
	if len(lines) != len(rows) {
		t.Fatalf("got %d lines for %d rows", len(lines), len(rows))
	}
	for _, l := range lines {
		if n := strings.Count(l, sep); n != 5 {
			t.Errorf("line has %d separators, want 5: %q", n, l)
		}
	}
	// Widths come from the widest chord (3), command (30, the gf one) and
	// group (6) in sample; the description is last and unpadded; the raw
	// command and mode follow verbatim.
	want := "gt " + sep + "git status                    " + sep + "git   " + sep + "file › list" + sep + "git status" + sep + "run"
	if lines[1] != want {
		t.Errorf("gt row:\n got %q\nwant %q", lines[1], want)
	}
	want = "gc " + sep + "git commit --amend            " + sep + "git   " + sep + "amend" + sep + "git commit --amend" + sep + "insert"
	if lines[6] != want {
		t.Errorf("gc[1] row:\n got %q\nwant %q", lines[6], want)
	}
	want = "   " + sep + "__zoxide_zi                   " + sep + "zoxide" + sep + "jump" + sep + "__zoxide_zi" + sep + "run"
	if lines[8] != want {
		t.Errorf("space chord row:\n got %q\nwant %q", lines[8], want)
	}
}

func TestPadCountsRunes(t *testing.T) {
	tests := []struct {
		in    string
		width int
		want  string
	}{
		{"ab", 4, "ab  "},
		{"a›b", 5, "a›b  "},
		{"abcdef", 3, "abcdef"},
		{"", 2, "  "},
	}
	for _, tc := range tests {
		if got := pad(tc.in, tc.width); got != tc.want {
			t.Errorf("pad(%q, %d) = %q, want %q", tc.in, tc.width, got, tc.want)
		}
	}
}

func TestModeCoversAllCombinations(t *testing.T) {
	tests := []struct {
		e    entry
		want string
	}{
		{entry{run: true}, "run"},
		{entry{}, "insert"},
		{entry{run: true, eval: true}, "eval-run"},
		{entry{eval: true}, "eval-insert"},
	}
	for _, tc := range tests {
		if got := tc.e.mode(); got != tc.want {
			t.Errorf("%+v: got %s, want %s", tc.e, got, tc.want)
		}
	}
}

func TestCmdWidthFitsTerminal(t *testing.T) {
	// sample's natural widths: chord 3, command 30, group 6, description 15
	// ("branch › switch"), so the fixed part of a row is 2+3+6+3+15 = 29.
	widths := [4]int{3, 30, 6, 15}
	tests := []struct {
		name string
		term int
		want int
	}{
		{"unknown width keeps the natural column", 0, 30},
		{"wide terminal keeps the natural column", 200, 30},
		{"exact fit keeps the natural column", 59, 30},
		{"tight terminal shrinks the column", 55, 26},
		{"very narrow terminal stops at the floor", 40, cmdFloor},
	}
	for _, tc := range tests {
		if got := cmdWidth(widths, tc.term); got != tc.want {
			t.Errorf("%s: cmdWidth(%d) = %d, want %d", tc.name, tc.term, got, tc.want)
		}
	}
	// A long description only reserves descReserve cells, never all of it.
	if got := cmdWidth([4]int{3, 100, 6, 80}, 120); got != 120-2-3-6-3-descReserve {
		t.Errorf("long description: got %d", got)
	}
}

func TestTruncateCountsRunes(t *testing.T) {
	tests := []struct {
		in    string
		width int
		want  string
	}{
		{"abc", 5, "abc"},
		{"abcd", 4, "abcd"},
		{"abcdef", 4, "abc…"},
		{"a›bcd", 3, "a›…"},
	}
	for _, tc := range tests {
		if got := truncate(tc.in, tc.width); got != tc.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", tc.in, tc.width, got, tc.want)
		}
	}
}

func TestRenderFitsCommandColumnToWidth(t *testing.T) {
	rows, _, err := parse("t", sample)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := render(&buf, rows, 55); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(buf.String(), "\n"), "\n")
	// Width 55 leaves 26 cells for commands: the 30-cell gf command is cut
	// with an ellipsis in the display column while its raw field is intact,
	// and shorter commands pad to the same 26.
	want := "gf " + sep + `git log --format="%h" | j…` + sep + "git   " + sep + "log" + sep + `git log --format="%h" | jq '.'` + sep + "run"
	if lines[7] != want {
		t.Errorf("gf row:\n got %q\nwant %q", lines[7], want)
	}
	want = "gt " + sep + "git status                " + sep + "git   " + sep + "file › list" + sep + "git status" + sep + "run"
	if lines[1] != want {
		t.Errorf("gt row:\n got %q\nwant %q", lines[1], want)
	}
}
