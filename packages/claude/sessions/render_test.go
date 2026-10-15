package main

import (
	"strings"
	"testing"
)

func TestInline(t *testing.T) {
	tests := []struct{ in, want string }{
		{"plain text", "plain text"},
		{"run `go test` now", "run " + codeFg + "go test" + reset + " now"},
		{"``a`b`` and `` `x` ``", codeFg + "a`b" + reset + " and " + codeFg + "`x`" + reset},
		{"**bold** *it* _it_", bold + "bold" + reset + " " + italic + "it" + reset + " " + italic + "it" + reset},
		{"***both***", bold + italic + "both" + reset + bold + reset},
		{"*a **b***", italic + "a " + bold + "b" + reset + italic + reset},
		{"**see `x`**", bold + "see " + codeFg + "x" + reset + bold + reset},
		{"~~gone~~ ~/x", strike + "gone" + reset + " ~/x"},
		{"snake_case and __claude_sessions", "snake_case and __claude_sessions"},
		{"2 * 3 * 4", "2 * 3 * 4"},
		{`\*not\* a\b`, `*not* a\b`},
		{"an unclosed ` and **", "an unclosed ` and **"},
		{"[docs](https://x.y) [https://x.y](https://x.y)", "docs" + dim + " (https://x.y)" + reset + " https://x.y"},
		{"[x] done", "[x] done"},
	}
	for _, tt := range tests {
		if got := inline(tt.in, ""); got != tt.want {
			t.Errorf("inline(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestMarkdown(t *testing.T) {
	in := strings.Join([]string{
		"# Top",
		"## Sub `x`",
		"> quoted *note*",
		">",
		"* one",
		"  - two",
		"3. three",
		"---",
		"```go",
		"x := `a` // **not** markdown",
		"```",
		"```",
		"plain code",
		"",
		"```",
		"after",
	}, "\n")
	want := strings.Join([]string{
		bold + italic + underline + "Top" + reset,
		bold + "Sub " + codeFg + "x" + reset + bold + reset,
		dim + "▎" + reset + " " + italic + "quoted " + italic + "note" + reset + italic + reset,
		"",
		"- one",
		"  - two",
		"3. three",
		"---",
		dim + "go" + reset,
		"x := `a` // **not** markdown",
		codeFg + "plain code" + fgOff,
		"",
		"after",
	}, "\n")
	if got := markdown(in); got != want {
		t.Errorf("markdown =\n%q\nwant\n%q", got, want)
	}
}

func TestPromptBlock(t *testing.T) {
	lead := promptBg + pointerFg + "❯" + fgOff + " "
	tests := []struct {
		text  string
		width int
		want  string
	}{
		{"fix it", 0, lead + "fix it" + reset},
		{"fix it", 10, lead + "fix it  " + reset},
		{"one two three", 10, lead + "one two " + reset + "\n" + promptBg + "  three   " + reset},
		{"a\n\tb", 0, lead + "a" + reset + "\n" + promptBg + "          b" + reset},
	}
	for _, tt := range tests {
		if got := promptBlock(tt.text, tt.width); got != tt.want {
			t.Errorf("promptBlock(%q, %d) = %q, want %q", tt.text, tt.width, got, tt.want)
		}
	}
}

func TestWrap(t *testing.T) {
	tests := []struct {
		line  string
		width int
		want  []string
	}{
		{"short", 10, []string{"short"}},
		{"any width", 0, []string{"any width"}},
		{"one two three", 7, []string{"one two", "three"}},
		{"abcdefghij", 4, []string{"abcd", "efgh", "ij"}},
		{"éèê àâ", 3, []string{"éèê", "àâ"}},
	}
	for _, tt := range tests {
		if got := wrap(tt.line, tt.width); strings.Join(got, "|") != strings.Join(tt.want, "|") {
			t.Errorf("wrap(%q, %d) = %q, want %q", tt.line, tt.width, got, tt.want)
		}
	}
}

func TestHangWrap(t *testing.T) {
	tests := []struct {
		in    string
		width int
		want  string
	}{
		{"fits\nand this", 10, "fits\nand this"},
		{"any width at all", 0, "any width at all"},
		{"● one two three", 10, "● one two\n  three"},
		{"  ⎿  alpha beta gamma", 14, "  ⎿  alpha\n     beta\n     gamma"},
		{"abcdefghijkl", 5, "abcde\nfghij\nkl"},
		{"● " + bold + "aaa bbb ccc" + reset, 7, "● " + bold + "aaa" + reset + "\n  " + bold + "bbb" + reset + "\n  " + bold + "ccc" + reset},
		{"\tx y", 9, "        x\n    y"},
		{"word1 word2   ", 8, "word1\nword2"},
		{promptBlock("fix it", 10), 10, promptBlock("fix it", 10)},
	}
	for _, tt := range tests {
		if got := hangWrap(tt.in, tt.width); got != tt.want {
			t.Errorf("hangWrap(%q, %d) =\n%q\nwant\n%q", tt.in, tt.width, got, tt.want)
		}
	}
}
