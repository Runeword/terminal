package main

import (
	"bytes"
	"strings"
	"testing"
)

// sample exercises every mode, a submenu array, a quoted chord, and groups
// whose file order differs from their sorted order.
const sample = `
[open]
oh = { cmd = 'nvim $HISTFILE', desc = 'history' }

[git]
gt  = { cmd = 'git status', desc = 'file › list' }
gbs = { cmd = '__git_branch_switch', desc = 'branch › switch', eval = true }
gbc = { cmd = 'git switch --create <branch>', desc = 'branch › new', run = false }
gdp = { cmd = '__git_patch', desc = 'patch', eval = true, run = false }
gc = [
  { cmd = 'git commit' },
  { cmd = 'git commit --amend', desc = 'amend', run = false },
]
gf = { cmd = "git log --format=\"%h\" | jq '.'" }

[zoxide]
" " = { cmd = '__zoxide_zi', desc = 'jump' }
`

func TestParseKeepsFileOrderAndModes(t *testing.T) {
	rows, err := parse(sample)
	if err != nil {
		t.Fatal(err)
	}
	want := []struct{ chord, group, cmd, desc, mode string }{
		{"oh", "open", "nvim $HISTFILE", "history", "run"},
		{"gt", "git", "git status", "file › list", "run"},
		{"gbs", "git", "__git_branch_switch", "branch › switch", "eval-run"},
		{"gbc", "git", "git switch --create <branch>", "branch › new", "insert"},
		{"gdp", "git", "__git_patch", "patch", "eval-insert"},
		{"gc", "git", "git commit", "", "run"},
		{"gc", "git", "git commit --amend", "amend", "insert"},
		{"gf", "git", `git log --format="%h" | jq '.'`, "", "run"},
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

func TestParseImplicitGroup(t *testing.T) {
	// A dotted key defines its group without a [header]; it must still be
	// registered, in file order.
	rows, err := parse("git.gt = { cmd = 'git status' }\n[nix]\nnb = { cmd = 'nix build' }\n")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 || rows[0].group != "git" || rows[1].group != "nix" {
		t.Fatalf("got %+v", rows)
	}
}

func TestParseErrors(t *testing.T) {
	tests := []struct{ name, src, want string }{
		{"duplicate chord", "[git]\ngt = { cmd = 'a' }\ngt = { cmd = 'b' }\n", "gt"},
		{"chord in two groups", "[git]\ngc = { cmd = 'a' }\n[gcloud]\ngc = { cmd = 'b' }\n", `chord "gc" is defined in both [git] and [gcloud]`},
		{"unknown field", "[git]\ngt = { cmd = 'a', evla = true }\n", `git.gt: unknown field "evla"`},
		{"missing cmd", "[git]\ngt = { desc = 'x' }\n", "git.gt: cmd is required"},
		{"blank cmd", "[git]\ngt = { cmd = '  ' }\n", "cmd is required"},
		{"cmd not a string", "[git]\ngt = { cmd = 1 }\n", "cmd must be a string"},
		{"run not a boolean", "[git]\ngt = { cmd = 'a', run = 'no' }\n", "run must be a boolean"},
		{"eval not a boolean", "[git]\ngt = { cmd = 'a', eval = 1 }\n", "eval must be a boolean"},
		{"chord is a string", "[git]\ngt = 'git status'\n", "git.gt: must be a table"},
		{"empty submenu", "[git]\ngt = []\n", "submenu is empty"},
		{"submenu item not a table", "[git]\ngt = ['a']\n", "submenu items must be tables"},
		{"submenu item error is indexed", "[git]\ngt = [{ cmd = 'a' }, { desc = 'b' }]\n", "git.gt: [1]: cmd is required"},
		{"tab in cmd", "[git]\ngt = { cmd = \"a\\tb\" }\n", "cmd must not contain"},
		{"separator in desc", "[git]\ngt = { cmd = 'a', desc = \"x\\u00A0y\" }\n", "desc must not contain"},
		{"separator in chord", "[git]\n\"g\\u00A0t\" = { cmd = 'a' }\n", "[git]: chord must not contain"},
		{"chord outside a group", "gt = { cmd = 'git status' }\n", "gt.cmd: must be a table"},
		{"group is a string", "git = 'x'\n", "expected a [git] table"},
		{"empty chord", "[git]\n\"\" = { cmd = 'a' }\n", "[git]: empty chord"},
		{"invalid toml", "[git\n", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parse(tc.src)
			if err == nil {
				t.Fatalf("expected an error containing %q", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %q does not contain %q", err, tc.want)
			}
		})
	}
}

func TestRenderPadsDisplayColumnsAndHidesDispatch(t *testing.T) {
	rows, err := parse(sample)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := render(&buf, rows); err != nil {
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
