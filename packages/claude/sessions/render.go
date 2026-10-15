package main

import (
	"strings"
	"unicode/utf8"
)

// The colors of Claude Code's dark theme, its default (2.1.287), so the
// preview draws a conversation as Claude Code does.
const (
	codeFg    = "\x1b[38;2;177;185;249m" // permission: code spans, code blocks without a language
	pointerFg = "\x1b[38;2;153;153;153m" // inactive: a prompt's ❯
	promptBg  = "\x1b[48;2;55;55;55m"    // userMessageBackground: a prompt's band
	okFg      = "\x1b[38;2;78;186;101m"  // success: a tool call's bullet
	errorFg   = "\x1b[38;2;255;107;128m" // error: a failed call's bullet

	fgOff     = "\x1b[39m"
	italic    = "\x1b[3m"
	underline = "\x1b[4m"
	strike    = "\x1b[9m"
)

// markdown renders a reply's markdown as Claude Code's formatter does: a code
// span in the code color, strong text bold, emphasis italic, strikethrough
// struck, a heading bold (italic and underlined too at the first level), a
// quote italic behind a dim bar, a list item behind "-" or its number, a link
// as its text with the address dim after it, and a code block in the code
// color, or plain under its language in dim when it has one: Claude Code
// highlights those, which the preview can't. The markup itself goes. Each
// line closes its own styles: fzf drops them at a line break.
func markdown(text string) string {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	fence, lang := "", "" // the open code block's fence and language
	for _, line := range lines {
		switch {
		case fence != "" && closesFence(line, fence):
			fence = ""
		case fence != "" && lang == "" && strings.TrimSpace(line) != "":
			out = append(out, codeFg+line+fgOff)
		case fence != "":
			out = append(out, line)
		default:
			f, l, ok := openFence(line)
			switch {
			case !ok:
				out = append(out, markdownLine(line))
			case l != "":
				out = append(out, dim+l+reset)
			}
			fence, lang = f, l
		}
	}
	return strings.Join(out, "\n")
}

// markdownLine renders one line outside a code block.
func markdownLine(line string) string {
	s := strings.TrimLeft(line, " ")
	indent := line[:len(line)-len(s)]
	if level := headingLevel(s); level > 0 {
		style := bold
		if level == 1 {
			style = bold + italic + underline
		}
		return indent + style + inline(strings.TrimSpace(s[level:]), style) + reset
	}
	if quoted, ok := strings.CutPrefix(s, ">"); ok {
		quoted = strings.TrimPrefix(quoted, " ")
		if strings.TrimSpace(quoted) == "" {
			return ""
		}
		return indent + dim + "▎" + reset + " " + italic + inline(quoted, italic) + reset
	}
	if thematicBreak(s) {
		return indent + "---"
	}
	if marker, item, ok := listItem(s); ok {
		return indent + marker + " " + inline(item, "")
	}
	return indent + inline(s, "")
}

// openFence reports whether line opens a code block, with the fence that
// closes it and the block's language.
func openFence(line string) (fence, lang string, ok bool) {
	s := strings.TrimLeft(line, " ")
	if len(line)-len(s) > 3 || s == "" || s[0] != '`' && s[0] != '~' {
		return "", "", false
	}
	n := runLen(s, 0, s[0])
	info := strings.TrimSpace(s[n:])
	if n < 3 || s[0] == '`' && strings.Contains(info, "`") {
		return "", "", false
	}
	lang, _, _ = strings.Cut(info, " ")
	return s[:n], lang, true
}

// closesFence reports whether line closes the code block that fence opened.
func closesFence(line, fence string) bool {
	s := strings.TrimSpace(line)
	return len(s) >= len(fence) && strings.Trim(s, fence[:1]) == ""
}

// headingLevel is the level of the heading line s opens, 0 for none.
func headingLevel(s string) int {
	n := runLen(s, 0, '#')
	if n < 1 || n > 6 || n < len(s) && s[n] != ' ' && s[n] != '\t' {
		return 0
	}
	return n
}

// thematicBreak reports whether s is a line of three or more -, * or _.
func thematicBreak(s string) bool {
	t := strings.ReplaceAll(strings.TrimSpace(s), " ", "")
	return len(t) >= 3 && strings.Contains("-*_", t[:1]) && strings.Count(t, t[:1]) == len(t)
}

// listItem splits the line of a list item into its marker, "-" for every
// bullet as Claude Code draws them, and its text.
func listItem(s string) (marker, item string, ok bool) {
	if len(s) >= 2 && strings.Contains("-*+", s[:1]) && s[1] == ' ' {
		return "-", s[2:], true
	}
	n := len(s) - len(strings.TrimLeft(s, "0123456789"))
	if n >= 1 && n <= 9 && n+1 < len(s) && (s[n] == '.' || s[n] == ')') && s[n+1] == ' ' {
		return s[:n+1], s[n+2:], true
	}
	return "", "", false
}

// inline renders the inline markdown of s. base is the style of the line
// around it, which each span puts back when it closes.
func inline(s, base string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		switch c {
		case '\\':
			if i+1 < len(s) && isPunct(s[i+1]) {
				b.WriteByte(s[i+1])
				i += 2
				continue
			}
		case '`':
			n := runLen(s, i, c)
			if j := codeEnd(s, i+n, n); j >= 0 {
				b.WriteString(codeFg + codeText(s[i+n:j]) + reset + base)
				i = j + n
				continue
			}
			b.WriteString(s[i : i+n]) // an unclosed run stays as typed
			i += n
			continue
		case '*', '_', '~':
			if inner, style, end, ok := emphasis(s, i); ok {
				b.WriteString(style + inline(inner, base+style) + reset + base)
				i = end
				continue
			}
			n := runLen(s, i, c)
			b.WriteString(s[i : i+n])
			i += n
			continue
		case '[':
			if text, url, end, ok := link(s, i); ok {
				b.WriteString(inline(text, base))
				if url != text {
					b.WriteString(dim + " (" + url + ")" + reset + base)
				}
				i = end
				continue
			}
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}

// emphasis reads the span that the run of *, _ or ~ at i opens: its inner
// text, its style and where its closing run ends. ** and __ make strong text,
// * and _ emphasis, ~~ strikethrough. A run opens with no space after it and
// closes with none before it, and _ neither opens nor closes inside a word,
// so snake_case stays as typed.
func emphasis(s string, i int) (inner, style string, end int, ok bool) {
	c := s[i]
	n := runLen(s, i, c)
	width := 1
	style = italic
	switch {
	case c == '~' && n != 2:
		return "", "", 0, false
	case c == '~':
		width, style = 2, strike
	case n >= 2:
		width, style = 2, bold
	}
	if i+n >= len(s) || isSpace(s[i+n]) || c == '_' && i > 0 && isWord(s[i-1]) {
		return "", "", 0, false
	}
	start := i + width
	for j := start; j < len(s); {
		switch s[j] {
		case '\\':
			j += 2
		case '`': // a closer can't sit inside a code span
			m := runLen(s, j, '`')
			if k := codeEnd(s, j+m, m); k >= 0 {
				j = k + m
			} else {
				j += m
			}
		case c:
			m := runLen(s, j, c)
			// A run of two closes strong text, not the emphasis around it.
			fits := m >= width && (width == 2 || m != 2)
			if fits && j > start && !isSpace(s[j-1]) && (c != '_' || j+m >= len(s) || !isWord(s[j+m])) {
				return s[start : j+m-width], style, j + m, true
			}
			j += m
		default:
			j++
		}
	}
	return "", "", 0, false
}

// link reads the link [text](url) at i: its text, its address and where it
// ends.
func link(s string, i int) (text, url string, end int, ok bool) {
	mid := strings.Index(s[i:], "](")
	if mid < 0 {
		return "", "", 0, false
	}
	mid += i
	stop := strings.IndexByte(s[mid+2:], ')')
	if stop < 0 {
		return "", "", 0, false
	}
	stop += mid + 2
	text, url = s[i+1:mid], s[mid+2:stop]
	if text == "" || url == "" || strings.ContainsAny(url, " \t") {
		return "", "", 0, false
	}
	return text, url, stop + 1, true
}

// codeEnd is where the run of n backticks closing a code span opened before
// from starts, -1 when none does.
func codeEnd(s string, from, n int) int {
	for j := from; j < len(s); {
		if s[j] != '`' {
			j++
			continue
		}
		m := runLen(s, j, '`')
		if m == n {
			return j
		}
		j += m
	}
	return -1
}

// codeText is a code span's text: one space goes from each end when both
// have one, so “ `x` “ can show its backticks.
func codeText(s string) string {
	if len(s) > 2 && s[0] == ' ' && s[len(s)-1] == ' ' && strings.Trim(s, " ") != "" {
		return s[1 : len(s)-1]
	}
	return s
}

// runLen is the length of the run of c that starts at i.
func runLen(s string, i int, c byte) int {
	n := 0
	for i+n < len(s) && s[i+n] == c {
		n++
	}
	return n
}

func isPunct(c byte) bool {
	return strings.IndexByte("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", c) >= 0
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t'
}

// isWord reports whether c belongs to a word: an ASCII letter or digit, or a
// byte of a non-ASCII character, most of which are letters in prose.
func isWord(c byte) bool {
	return c >= 0x80 || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

// promptBlock renders a prompt as Claude Code draws one: on a band of the gray
// of a user message, the ❯ in the inactive gray, the text from the third
// column. Given width, the preview's (fzf's $FZF_PREVIEW_COLUMNS), each line
// is wrapped short of it and padded to it, so the band spans the preview.
func promptBlock(text string, width int) string {
	var lines []string
	for _, l := range strings.Split(text, "\n") {
		lines = append(lines, wrap(expandTabs(l), width-3)...)
	}
	for i, l := range lines {
		lead := "  "
		if i == 0 {
			lead = pointerFg + "❯" + fgOff + " "
		}
		pad := strings.Repeat(" ", max(0, width-2-utf8.RuneCountInString(l)))
		lines[i] = promptBg + lead + l + pad + reset
	}
	return strings.Join(lines, "\n")
}

// wrap cuts line into pieces of at most width runes, at a space where there
// is one. A width under 1 leaves it whole.
func wrap(line string, width int) []string {
	r := []rune(line)
	if width < 1 || len(r) <= width {
		return []string{line}
	}
	var out []string
	for len(r) > width {
		cut := width
		for k := width; k > 0; k-- {
			if r[k] == ' ' {
				cut = k
				break
			}
		}
		out = append(out, strings.TrimRight(string(r[:cut]), " "))
		r = []rune(strings.TrimLeft(string(r[cut:]), " "))
	}
	if len(r) > 0 {
		out = append(out, string(r))
	}
	return out
}

// expandTabs turns each tab into the spaces up to the next multiple of 8
// columns, as fzf shows it.
func expandTabs(s string) string {
	if !strings.Contains(s, "\t") {
		return s
	}
	var b strings.Builder
	col := 0
	for _, r := range s {
		if r == '\t' {
			n := 8 - col%8
			b.WriteString(strings.Repeat(" ", n))
			col += n
			continue
		}
		b.WriteRune(r)
		col++
	}
	return b.String()
}

// hangWrap fits each line of text to width columns as Claude Code wraps one,
// under its own indentation: a line too long breaks at its last space that
// fits, or where it must, and goes on indented past its bullet or ⎿, the
// styles it had open restored. A width under 1 leaves text as it is.
func hangWrap(text string, width int) string {
	if width < 1 {
		return text
	}
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, wrapLine(l, width)...)
	}
	return strings.Join(out, "\n")
}

// cell is a piece of a line: a rune one column wide, or an SGR sequence,
// none.
type cell struct {
	s     string
	width int
}

// wrapLine is hangWrap for one line.
func wrapLine(line string, width int) []string {
	if len(line) <= width && !strings.Contains(line, "\t") { // bytes bound columns
		return []string{line}
	}
	cells, cols := cellsOf(line)
	if cols <= width {
		return []string{line}
	}
	// Trailing spaces would wrap into a row of their own.
	for i := len(cells) - 1; i >= 0 && (cells[i].s == " " || cells[i].width == 0); i-- {
		if cells[i].s == " " {
			cells = append(cells[:i], cells[i+1:]...)
		}
	}
	indent := hangIndent(cells)
	hang := strings.Repeat(" ", min(indent, width/2))
	var rows []string
	active := "" // the styles open where a row starts
	// The first row can't break inside its own indentation.
	for start, limit, minBreak := 0, width, indent; start < len(cells); limit, minBreak = width-len(hang), 0 {
		for start > 0 && start < len(cells) && cells[start].s == " " {
			start++ // a row doesn't start with the space it broke at
		}
		end, used, space := start, 0, -1
		for end < len(cells) && used+cells[end].width <= limit {
			if cells[end].s == " " && used > minBreak {
				space = end
			}
			used += cells[end].width
			end++
		}
		if end < len(cells) && space > start {
			end = space
		}
		var row strings.Builder
		if start > 0 {
			row.WriteString(hang + active)
		}
		for _, c := range cells[start:end] {
			row.WriteString(c.s)
			switch {
			case c.width > 0:
			case c.s == reset || c.s == "\x1b[m":
				active = ""
			default:
				active += c.s
			}
		}
		if active != "" && end < len(cells) {
			row.WriteString(reset)
		}
		rows = append(rows, row.String())
		start = end
	}
	return rows
}

// cellsOf splits line into its cells, a tab into the spaces up to the next
// stop of 8, as fzf shows one, and counts its columns.
func cellsOf(line string) (cells []cell, cols int) {
	for i := 0; i < len(line); {
		if line[i] == 0x1b {
			end := escapeEnd(line, i)
			cells = append(cells, cell{line[i:end], 0})
			i = end
			continue
		}
		r, size := utf8.DecodeRuneInString(line[i:])
		if r == '\t' {
			for n := 8 - cols%8; n > 0; n-- {
				cells = append(cells, cell{" ", 1})
				cols++
			}
		} else {
			cells = append(cells, cell{line[i : i+size], 1})
			cols++
		}
		i += size
	}
	return cells, cols
}

// hangIndent is how far a line's wrapped rows go in: past its indentation and
// the bullet, ⎿, bar or list marker after it.
func hangIndent(cells []cell) int {
	var plain strings.Builder
	for _, c := range cells {
		if c.width > 0 {
			plain.WriteString(c.s)
		}
	}
	s := plain.String()
	n := len(s) - len(strings.TrimLeft(s, " "))
	for _, mark := range []string{"⎿  ", "● ", "✻ ", "▎ ", "- ", "❯ "} {
		if strings.HasPrefix(s[n:], mark) {
			return n + utf8.RuneCountInString(mark)
		}
	}
	return n
}
