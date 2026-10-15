package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// transcript writes the conversation in data, a session's transcript file:
// every prompt and reply, Claude's thinking where the file kept its text, and
// each tool call with its whole input and complete result. It reads only the
// records that hold the Claude API's messages, which the Agent SDK hands out
// too (get_session_messages); what Claude Code adds around them for itself,
// it leaves out.
func transcript(w *bytes.Buffer, data []byte, width int) {
	var records []entry
	results := map[string]block{} // tool results, by the id of the call each answers
	for _, line := range bytes.Split(data, []byte("\n")) {
		var e entry
		if len(line) == 0 || json.Unmarshal(line, &e) != nil || e.IsSidechain {
			continue
		}
		records = append(records, e)
		if e.Type != "user" {
			continue
		}
		for _, b := range e.blocks() {
			if b.Type == "tool_result" {
				results[b.ToolUseID] = b
			}
		}
	}
	for _, e := range records {
		switch {
		case e.Type == "user" && !e.IsMeta && !e.IsCompactSummary:
			for _, b := range e.blocks() {
				userBlock(w, b, width)
			}
		case e.Type == "assistant":
			for _, b := range e.blocks() {
				assistantBlock(w, b, results)
			}
		}
	}
}

// userBlock writes a block of a user record: a prompt, or an image sent with
// one. Tool results are written under their calls instead.
func userBlock(w *bytes.Buffer, b block, width int) {
	switch b.Type {
	case "text":
		if p := prompt(b.Text); p != "" {
			fmt.Fprintf(w, "\n%s\n", promptBlock(p, width))
		}
	case "image":
		fmt.Fprintf(w, "\n%s\n", promptBlock("[Image]", width))
	}
}

// assistantBlock writes a block of a reply: its text behind a bullet, its
// thinking when the transcript kept the text, or a tool call with its
// result.
func assistantBlock(w *bytes.Buffer, b block, results map[string]block) {
	switch b.Type {
	case "text":
		if text := strings.TrimSpace(cleanText(b.Text)); text != "" {
			fmt.Fprintf(w, "\n%s\n", hang("●", markdown(text)))
		}
	case "thinking":
		if text := strings.TrimSpace(cleanText(b.Thinking)); text != "" {
			fmt.Fprintf(w, "\n%s\n%s\n", styled(dim+italic, "✻ Thinking…"), indent(styled(dim+italic, text), "  "))
		}
	case "tool_use":
		res, answered := results[b.ID]
		fmt.Fprintf(w, "\n%s", toolCall(b, res, answered))
	}
}

// toolCall renders a tool call: a bullet, green, or red when the call failed,
// or dim when it never got a result, and the tool's name; its input fields in
// the order the transcript holds them; then its complete result.
func toolCall(b block, res block, answered bool) string {
	var out strings.Builder
	bullet := dim
	if answered {
		bullet = okFg
		if res.IsError {
			bullet = errorFg
		}
	}
	out.WriteString(bullet + "●" + reset + " " + bold + clean(b.Name) + reset + "\n")
	for _, f := range fieldsOf(b.Input) {
		value := strings.ReplaceAll(cleanText(valueText(f.value)), "\n", "\n  ")
		out.WriteString(indent(dim+clean(f.key)+":"+reset+" "+value, "  ") + "\n")
	}
	if answered {
		color := ""
		if res.IsError {
			color = errorFg
		}
		out.WriteString(elbow(contentText(res.Content), color))
	}
	return out.String()
}

// elbow hangs text under a "⎿", as Claude Code hangs a result under its
// call, in color when one is given. Its own colors stay, its other control
// sequences go; no text shows as "(No content)".
func elbow(text, color string) string {
	text = strings.TrimRight(keepSGR(text), "\n")
	if strings.TrimSpace(text) == "" {
		return "  ⎿  " + dim + "(No content)" + reset + "\n"
	}
	var out strings.Builder
	for i, l := range strings.Split(text, "\n") {
		prefix := "     "
		if i == 0 {
			prefix = "  ⎿  "
		}
		if color != "" || strings.Contains(l, "\x1b") {
			l = color + l + reset
		}
		out.WriteString(prefix + l + "\n")
	}
	return out.String()
}

// keepSGR drops the control characters of s, all but newlines, tabs and the
// SGR sequences that color text: output keeps its colors, but can't move the
// cursor, retitle the terminal or reach the clipboard.
func keepSGR(s string) string {
	var out strings.Builder
	for i := 0; i < len(s); {
		if s[i] == 0x1b {
			end := escapeEnd(s, i)
			if s[end-1] == 'm' && end-i >= 3 && s[i+1] == '[' && strings.Trim(s[i+2:end-1], "0123456789;:") == "" {
				out.WriteString(s[i:end])
			}
			i = end
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == '\n' || r == '\t' || !control(r) {
			out.WriteString(s[i : i+size])
		}
		i += size
	}
	return out.String()
}

// escapeEnd is where the escape sequence that starts at s[i] ends: a CSI
// sequence at its final byte, an OSC or other string sequence at its BEL or
// ST, anything else after the byte that follows the ESC.
func escapeEnd(s string, i int) int {
	if i+1 >= len(s) {
		return len(s)
	}
	switch s[i+1] {
	case '[':
		for j := i + 2; j < len(s); j++ {
			if s[j] >= 0x40 && s[j] <= 0x7e {
				return j + 1
			}
		}
		return len(s)
	case ']', 'P', '_', '^', 'X':
		for j := i + 2; j < len(s); j++ {
			if s[j] == 0x07 {
				return j + 1
			}
			if s[j] == 0x1b && j+1 < len(s) && s[j+1] == '\\' {
				return j + 2
			}
		}
		return len(s)
	}
	return i + 2
}

// field is one field of a tool call's input.
type field struct {
	key   string
	value json.RawMessage
}

// fieldsOf reads a tool call's input object, keeping its fields in the
// order Claude wrote them.
func fieldsOf(input json.RawMessage) []field {
	dec := json.NewDecoder(bytes.NewReader(input))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil
	}
	var fields []field
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			break
		}
		key, _ := t.(string)
		var v json.RawMessage
		if dec.Decode(&v) != nil {
			break
		}
		fields = append(fields, field{key, v})
	}
	return fields
}

// valueText is a JSON value as text: a string as itself, anything else as
// indented JSON.
func valueText(v json.RawMessage) string {
	var s string
	if json.Unmarshal(v, &s) == nil {
		return s
	}
	var out bytes.Buffer
	if json.Indent(&out, v, "", "  ") != nil {
		return string(v)
	}
	return out.String()
}

// contentText is a message's content as text: a string as itself, blocks
// as their text, an image as [Image] and a tool reference as its tool's
// name.
func contentText(v json.RawMessage) string {
	var s string
	if json.Unmarshal(v, &s) == nil {
		return s
	}
	var blocks []block
	_ = json.Unmarshal(v, &blocks) // no blocks is no text
	parts := make([]string, 0, len(blocks))
	for _, b := range blocks {
		switch b.Type {
		case "text":
			parts = append(parts, b.Text)
		case "image":
			parts = append(parts, "[Image]")
		case "tool_reference":
			parts = append(parts, b.ToolName)
		}
	}
	return strings.Join(parts, "\n")
}

// hang puts mark before text's first line and indents its other lines under
// it, as Claude Code lays out a message behind its bullet.
func hang(mark, text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		switch {
		case i == 0:
			lines[i] = mark + " " + l
		case l != "":
			lines[i] = "  " + l
		}
	}
	return strings.Join(lines, "\n")
}

// indent puts prefix before every line of text but the empty ones.
func indent(text, prefix string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = prefix + l
		}
	}
	return strings.Join(lines, "\n")
}

// styled wraps each line of text in style, which fzf would otherwise drop at
// the first line break.
func styled(style, text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = style + l + reset
	}
	return strings.Join(lines, "\n")
}
