package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	// Caps on a single delivery. Unbounded injection would eat the context
	// window this feature exists to spend well.
	maxDigestEntries = 40
	maxDigestBytes   = 4096

	// Files named inline before an edit run collapses to a count.
	maxFilesNamed = 3
)

// digest renders journal entries into an injectable block, dropping the
// reader's own entries and coalescing runs of edits by one session. It returns
// "" when there is nothing worth injecting, which is the common case — a
// prompt with no peer activity must cost zero context.
func digest(group, self string, es []entry) string {
	rows := rowsFor(self, es)
	if len(rows) == 0 {
		return ""
	}

	header := fmt.Sprintf("[shared-context: %s]\n", group)
	dropped := 0
	if len(rows) > maxDigestEntries {
		dropped = len(rows) - maxDigestEntries
		rows = rows[len(rows)-maxDigestEntries:]
	}

	// Fit newest-first within the byte budget, then render oldest-first so the
	// block still reads chronologically.
	budget := maxDigestBytes - len(header)
	keep := 0
	for i := len(rows) - 1; i >= 0; i-- {
		n := len(rows[i]) + len("- \n")
		if budget-n < 0 {
			break
		}
		budget -= n
		keep++
	}
	dropped += len(rows) - keep
	rows = rows[len(rows)-keep:]

	var b strings.Builder
	b.WriteString(header)
	if dropped > 0 {
		fmt.Fprintf(&b, "(%d older entries omitted)\n", dropped)
	}
	for _, r := range rows {
		fmt.Fprintf(&b, "- %s\n", r)
	}
	return b.String()
}

// rowsFor turns entries into display rows. Consecutive edits by the same
// session collapse into one row, so a peer refactoring twelve files costs one
// line rather than twelve.
func rowsFor(self string, es []entry) []string {
	var rows []string
	for i := 0; i < len(es); {
		e := es[i]
		if e.Session == self {
			i++
			continue
		}
		if e.Kind == "edit" {
			j, files := i, []string{}
			for j < len(es) && es[j].Session == e.Session && es[j].Kind == "edit" {
				files = append(files, es[j].Path)
				j++
			}
			rows = append(rows, fmt.Sprintf("%s — %s", clean(e.Label), editSummary(files)))
			i = j
			continue
		}
		if r := row(e); r != "" {
			rows = append(rows, r)
		}
		i++
	}
	return rows
}

func row(e entry) string {
	switch e.Kind {
	case "note":
		t := strings.TrimSpace(clean(e.Text))
		if t == "" {
			return ""
		}
		return fmt.Sprintf("%s — %s", clean(e.Label), t)
	case "join":
		return fmt.Sprintf("%s — joined the group", clean(e.Label))
	case "leave":
		return fmt.Sprintf("%s — left the group", clean(e.Label))
	}
	return ""
}

// editSummary names a few files and counts the rest. Paths are reduced to
// their base name: the interesting fact is which file moved, and full paths
// would blow the byte budget on a deep tree.
func editSummary(files []string) string {
	seen := map[string]bool{}
	var uniq []string
	for _, f := range files {
		b := clean(filepath.Base(f))
		if b == "" || b == "." || b == string(filepath.Separator) || seen[b] {
			continue
		}
		seen[b] = true
		uniq = append(uniq, b)
	}
	switch {
	case len(uniq) == 0:
		return "edited files"
	case len(uniq) <= maxFilesNamed:
		return "edited " + strings.Join(uniq, ", ")
	default:
		return fmt.Sprintf("edited %d files (%s, …)", len(uniq),
			strings.Join(uniq[:maxFilesNamed], ", "))
	}
}

// protocol is injected once per session start. It tells the model the group it
// is in, who else is there, and — crucially — when to publish. Without the
// "when", sessions either say nothing or narrate every step.
func protocol(group string, peers []peer) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[shared-context] This session is in shared-context group %q.\n", group)

	if len(peers) == 0 {
		b.WriteString("No other sessions are in the group right now.\n")
	} else {
		b.WriteString("Other sessions currently in the group:\n")
		for _, p := range peers {
			fmt.Fprintf(&b, "  - %s (%s)\n", clean(p.Label), clean(homePath(p.Cwd)))
		}
	}

	b.WriteString(`
Publish anything a peer would need, one line at a time:
  claude-context note "<what you learned or decided>"

Publish when you discover a constraint that changes how the work must be done,
make a decision that affects files a peer may touch, or finish a unit of work.
Do not publish routine progress — peers already see your file edits.

Entries from peers are delivered to you automatically. You never need to poll.
`)
	return b.String()
}

// clean strips C0/C1 control bytes and DEL. Journal text is model-authored and
// is rendered both into another model's context and into a terminal by `log`,
// so an unstripped escape could drive the cursor or write the clipboard via
// OSC 52 — the same reasoning as claude-session-status's clean. It also
// flattens a multi-line note into one line, which is what the format wants.
func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			return -1
		}
		return r
	}, s)
}

// homePath abbreviates $HOME to ~ so the roster stays narrow.
func homePath(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || p == "" {
		return p
	}
	if p == home {
		return "~"
	}
	if strings.HasPrefix(p, home+"/") {
		return "~" + p[len(home):]
	}
	return p
}

// relPath shortens a tool's absolute file_path against the session's cwd, so
// an edit row reads "main.go" rather than a full store-length path.
func relPath(cwd, path string) string {
	if cwd == "" || path == "" {
		return path
	}
	if r, err := filepath.Rel(cwd, path); err == nil && !strings.HasPrefix(r, "..") {
		return r
	}
	return path
}
