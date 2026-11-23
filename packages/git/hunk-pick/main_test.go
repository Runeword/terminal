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

	// r.txt's zero-context hunks, as the picker's diff has them: A, B and C
	// added after line 1, X after 5 (line 9, after the three before it), and 8
	// removed (after line 11 of the new side, past the four added before it).
	rHeader = "diff --git a/r.txt b/r.txt\n" +
		"index 9999999..aaaaaaa 100644\n" +
		"--- a/r.txt\n+++ b/r.txt\n"
	rHunk1 = "@@ -1,0 +2,3 @@\n+A\n+B\n+C\n"
	rHunk2 = "@@ -5,0 +9 @@ five\n+X\n"
	rHunk3 = "@@ -8 +11,0 @@\n-8\n"
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
		if err := rebase(io.Discard, files, []int{n}); err == nil {
			t.Errorf("rebase index %d: expected out-of-range error, got nil", n)
		}
	}
}

// TestRebase: each hunk picked moves past the hunks left out before it in its
// file, its old start up and its new start down by the lines they add (see
// rebase), and stays as git wrote it with none left out before it.
func TestRebase(t *testing.T) {
	rDiff := rHeader + rHunk1 + rHunk2 + rHunk3
	tests := []struct {
		name string
		diff string
		idx  []int
		want string
	}{
		{"all hunks: as git wrote them", rDiff, []int{1, 2, 3}, rDiff},
		{"the first hunk alone: as git wrote it", rDiff, []int{1}, rHeader + rHunk1},
		{"after a left out hunk adding 3", rDiff, []int{2}, rHeader + "@@ -8,0 +6 @@ five\n+X\n"},
		{"after left out hunks adding 4", rDiff, []int{3}, rHeader + "@@ -12 +7,0 @@\n-8\n"},
		{"past the left out hunk only", rDiff, []int{1, 3}, rHeader + rHunk1 + "@@ -9 +10,0 @@\n-8\n"},
		{"each by those left out before it", rDiff, []int{2, 3}, rHeader + "@@ -8,0 +6 @@ five\n+X\n" + "@@ -11 +8,0 @@\n-8\n"},
		{
			"a left out hunk adding as many as it removes",
			rHeader + "@@ -2 +2 @@\n-b\n+B\n" + "@@ -5,0 +6 @@ five\n+X\n",
			[]int{2},
			rHeader + "@@ -5,0 +6 @@ five\n+X\n",
		},
		{"context lines count", sampleDiff, []int{2}, fooHeader + "@@ -11,2 +10,3 @@\n kappa\n+lambda\n mu\n"},
		{"a file's hunks move for its own alone", rDiff + barHeader + barHunk1, []int{2, 4}, rHeader + "@@ -8,0 +6 @@ five\n+X\n" + barHeader + barHunk1},
		{"empty selection yields empty patch", rDiff, nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			files, err := parseDiff(strings.NewReader(tt.diff))
			if err != nil {
				t.Fatal(err)
			}
			var b strings.Builder
			if err := rebase(&b, files, tt.idx); err != nil {
				t.Fatalf("rebase(%v): %v", tt.idx, err)
			}
			if got := b.String(); got != tt.want {
				t.Errorf("rebase(%v) =\n%q\nwant\n%q", tt.idx, got, tt.want)
			}
		})
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
		{"quoted path unquoted", "+++ \"b/caf\\303\\251 \\\"x\\\".txt\"\n", "café \"x\".txt", true},
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

// TestPick checks assemble --sum: the patch comes out only while the hunks
// still have the digest they were picked with (of them as git wrote them), and
// then rebased for git apply; with no sum, as git wrote it (the preview's).
func TestPick(t *testing.T) {
	picked := patchSum([]byte(fooHeader + fooHunk2))
	// fooHunk2's file after an edit above it: a new hunk takes index 2.
	inserted := fooHeader + fooHunk1 + "@@ -5 +6 @@\n-e\n+E\n" + fooHunk2
	tests := []struct {
		name, diff string
		idx        []int
		sum        string
		want       string // the patch, or the refusal
	}{
		{"no sum: any patch", sampleDiff, []int{2}, "", fooHeader + fooHunk2},
		{"the picked hunks, past the one left out", sampleDiff, []int{2}, picked, fooHeader + "@@ -11,2 +10,3 @@\n kappa\n+lambda\n mu\n"},
		{"another hunk at the picked index", inserted, []int{2}, picked, "foo.txt changed since its hunks were picked; pick again"},
		{"the hunks are gone", "", []int{2}, picked, "the picked hunks are gone (the file changed since the pick); pick again"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			files, err := parseDiff(strings.NewReader(tt.diff))
			if err != nil {
				t.Fatal(err)
			}
			var b strings.Builder
			got := ""
			if err := pick(&b, files, tt.idx, tt.sum); err != nil {
				got = err.Error()
			}
			if got == "" {
				got = b.String()
			} else if b.Len() > 0 {
				t.Errorf("refused, but wrote %q", b.String())
			}
			if got != tt.want {
				t.Errorf("pick = %q, want %q", got, tt.want)
			}
		})
	}
}
