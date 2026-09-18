package main

import (
	"io"
	"strings"
	"testing"
)

// Diff fixtures are composed from named pieces so the same constants define the
// input and the expected assemble output (single source of truth).
const (
	fooHeader = "diff --git a/foo.txt b/foo.txt\n" +
		"index 1111111..2222222 100644\n" +
		"--- a/foo.txt\n+++ b/foo.txt\n"
	fooHunk1 = "@@ -1,3 +1,4 @@\n alpha\n+beta\n gamma\n delta\n"
	fooHunk2 = "@@ -10,2 +11,3 @@\n kappa\n+lambda\n mu\n"

	barHeader = "diff --git a/bar.txt b/bar.txt\n" +
		"index 3333333..4444444 100644\n" +
		"--- a/bar.txt\n+++ b/bar.txt\n"
	barHunk1 = "@@ -5,2 +5,2 @@\n-old\n+new\n tail\n"

	// A hunk whose file ends without a trailing newline.
	noNewlineDiff = "diff --git a/n.txt b/n.txt\n" +
		"index 5555555..6666666 100644\n" +
		"--- a/n.txt\n+++ b/n.txt\n" +
		"@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n"

	// A binary change carries no selectable hunk.
	binaryHeader = "diff --git a/img.png b/img.png\n" +
		"index 7777777..8888888 100644\n" +
		"Binary files a/img.png and b/img.png differ\n"
)

// sampleDiff: two files, three hunks (foo#1, foo#2, bar#1 -> indices 1,2,3).
var sampleDiff = fooHeader + fooHunk1 + fooHunk2 + barHeader + barHunk1

// binaryDiff: a binary file (no hunk) followed by one text hunk (index 1).
var binaryDiff = binaryHeader + fooHeader + fooHunk1

func runList(t *testing.T, diff string) string {
	t.Helper()
	files, err := parseDiff(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("parseDiff: %v", err)
	}
	var b strings.Builder
	if err := list(&b, files); err != nil {
		t.Fatalf("list: %v", err)
	}
	return b.String()
}

func runAssemble(t *testing.T, diff string, idx ...int) string {
	t.Helper()
	files, err := parseDiff(strings.NewReader(diff))
	if err != nil {
		t.Fatalf("parseDiff: %v", err)
	}
	var b strings.Builder
	if err := assemble(&b, files, idx); err != nil {
		t.Fatalf("assemble(%v): %v", idx, err)
	}
	return b.String()
}

func TestList(t *testing.T) {
	tests := []struct {
		name string
		diff string
		want string
	}{
		{
			"two files three hunks",
			sampleDiff,
			"1\tfoo.txt @@ -1,3 +1,4 @@\n" +
				"2\tfoo.txt @@ -10,2 +11,3 @@\n" +
				"3\tbar.txt @@ -5,2 +5,2 @@\n",
		},
		{"empty diff", "", ""},
		{"binary skipped", binaryDiff, "1\tfoo.txt @@ -1,3 +1,4 @@\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := runList(t, tt.diff); got != tt.want {
				t.Errorf("list =\n%q\nwant\n%q", got, tt.want)
			}
		})
	}
}

func TestAssemble(t *testing.T) {
	tests := []struct {
		name string
		diff string
		idx  []int
		want string
	}{
		{"single middle hunk", sampleDiff, []int{2}, fooHeader + fooHunk2},
		{"across two files", sampleDiff, []int{1, 3}, fooHeader + fooHunk1 + barHeader + barHunk1},
		{"reordered input sorts to diff order", sampleDiff, []int{3, 1}, fooHeader + fooHunk1 + barHeader + barHunk1},
		{"duplicates collapse", sampleDiff, []int{1, 1, 2}, fooHeader + fooHunk1 + fooHunk2},
		{"all hunks round-trip", sampleDiff, []int{1, 2, 3}, sampleDiff},
		{"no-newline marker preserved", noNewlineDiff, []int{1}, noNewlineDiff},
		{"binary offset ignored", binaryDiff, []int{1}, fooHeader + fooHunk1},
		{"empty selection yields empty patch", sampleDiff, nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := runAssemble(t, tt.diff, tt.idx...); got != tt.want {
				t.Errorf("assemble(%v) =\n%q\nwant\n%q", tt.idx, got, tt.want)
			}
		})
	}
}

func TestAssembleOutOfRange(t *testing.T) {
	files, err := parseDiff(strings.NewReader(sampleDiff))
	if err != nil {
		t.Fatalf("parseDiff: %v", err)
	}
	for _, n := range []int{0, -1, 4, 99} {
		if err := assemble(io.Discard, files, []int{n}); err == nil {
			t.Errorf("assemble index %d: expected out-of-range error, got nil", n)
		}
	}
}

func TestHeaderPath(t *testing.T) {
	tests := []struct {
		name string
		line string
		want string
		ok   bool
	}{
		{"plus b-side", "+++ b/foo.txt\n", "foo.txt", true},
		{"minus a-side", "--- a/foo.txt\n", "foo.txt", true},
		{"plus dev-null (delete)", "+++ /dev/null\n", "", false},
		{"minus dev-null (add)", "--- /dev/null", "", false},
		{"non-path header", "index 1111111..2222222 100644\n", "", false},
		{"unprefixed path", "+++ foo.txt\n", "foo.txt", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := headerPath(tt.line)
			if got != tt.want || ok != tt.ok {
				t.Errorf("headerPath(%q) = (%q, %v), want (%q, %v)", tt.line, got, ok, tt.want, tt.ok)
			}
		})
	}
}
