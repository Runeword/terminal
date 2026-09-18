// Command git-hunk-pick splits a unified git diff (read on stdin) into
// individually selectable hunks and reassembles a chosen subset into a valid
// patch. It backs the interactive hunk pickers in git.bash (the `grd`/`gru`
// leader aliases): `list` feeds fzf one line per hunk, and `assemble` emits the
// picked hunks — grouped under each file's original header, in ascending diff
// order — as a patch that `git apply --reverse` (optionally `--cached`) applies
// to unstage or discard exactly those hunks.
//
// Only whole, unmodified hunks are ever emitted, so the reconstructed patch is
// always valid: each hunk's b-side line numbers are absolute, so any subset
// still applies cleanly. Files with no hunks (binary patches, mode-only or
// pure-rename changes) and combined ("@@@") merge diffs carry nothing
// selectable and are skipped.
//
// Usage:
//
//	git-hunk-pick list               <diff   # INDEX<TAB>LABEL per hunk, 1-based
//	git-hunk-pick assemble INDEX...  <diff   # patch of those hunks
package main

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

// fileDiff is one file's section of a unified diff: its header block (every
// line from "diff --git" up to the first hunk) and its verbatim hunks (each
// starting at an "@@" line and ending before the next hunk or file).
type fileDiff struct {
	path   string
	header string
	hunks  []string
}

// splitLines splits s into lines, each keeping its trailing "\n" so that
// concatenating any subset round-trips byte-for-byte. A final line with no
// newline is returned unterminated.
func splitLines(s string) []string {
	var lines []string
	for len(s) > 0 {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			lines = append(lines, s)
			break
		}
		lines = append(lines, s[:i+1])
		s = s[i+1:]
	}
	return lines
}

// headerPath extracts the file path from a "--- a/x" or "+++ b/x" header line,
// stripping the a// b/ prefix. It reports false for a "/dev/null" side (an add
// or delete) so the caller keeps the real path from the other side.
func headerPath(line string) (string, bool) {
	s := strings.TrimRight(line, "\r\n")
	var rest string
	switch {
	case strings.HasPrefix(s, "+++ "):
		rest = s[len("+++ "):]
	case strings.HasPrefix(s, "--- "):
		rest = s[len("--- "):]
	default:
		return "", false
	}
	if rest == "/dev/null" {
		return "", false
	}
	if strings.HasPrefix(rest, "a/") || strings.HasPrefix(rest, "b/") {
		rest = rest[2:]
	}
	return rest, true
}

// parseDiff groups a unified diff into per-file sections. Any content before
// the first "diff --git" line (git never emits such a preamble) is ignored.
func parseDiff(r io.Reader) ([]fileDiff, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}

	var files []fileDiff
	cur := -1
	inHunk := false
	for _, line := range splitLines(string(data)) {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			files = append(files, fileDiff{header: line})
			cur = len(files) - 1
			inHunk = false
		case cur < 0:
			continue
		case strings.HasPrefix(line, "@@ "):
			files[cur].hunks = append(files[cur].hunks, line)
			inHunk = true
		case inHunk:
			files[cur].hunks[len(files[cur].hunks)-1] += line
		default:
			files[cur].header += line
			if p, ok := headerPath(line); ok {
				files[cur].path = p
			}
		}
	}
	return files, nil
}

// hunkLabel is the first ("@@ ...") line of a hunk without its terminator, used
// as the human-readable half of a list entry.
func hunkLabel(hunk string) string {
	if i := strings.IndexByte(hunk, '\n'); i >= 0 {
		return strings.TrimRight(hunk[:i], "\r")
	}
	return hunk
}

// list writes one "INDEX<TAB>path @@-header" line per hunk, indices 1-based in
// diff order, for fzf to present (field 2..) and return (field 1 = index). It
// returns the first write error, if any.
func list(w io.Writer, files []fileDiff) error {
	idx := 0
	for _, f := range files {
		for _, h := range f.hunks {
			idx++
			if _, err := fmt.Fprintf(w, "%d\t%s %s\n", idx, f.path, hunkLabel(h)); err != nil {
				return err
			}
		}
	}
	return nil
}

// hunkRef locates a hunk by its file and within-file position.
type hunkRef struct {
	file, hunk int
}

// flatten indexes every hunk by its global position, so refs[n-1] resolves the
// 1-based index n emitted by list.
func flatten(files []fileDiff) []hunkRef {
	var out []hunkRef
	for fi := range files {
		for hi := range files[fi].hunks {
			out = append(out, hunkRef{fi, hi})
		}
	}
	return out
}

// assemble writes a patch containing exactly the hunks named by the 1-based
// indices, de-duplicated and re-sorted into diff order (which git apply
// requires), each file's header emitted once before its first kept hunk.
func assemble(w io.Writer, files []fileDiff, indices []int) error {
	refs := flatten(files)

	seen := make(map[int]bool, len(indices))
	ordered := make([]int, 0, len(indices))
	for _, n := range indices {
		if n < 1 || n > len(refs) {
			return fmt.Errorf("hunk index %d out of range (have %d)", n, len(refs))
		}
		if !seen[n] {
			seen[n] = true
			ordered = append(ordered, n)
		}
	}
	sort.Ints(ordered)

	lastFile := -1
	for _, n := range ordered {
		r := refs[n-1]
		if r.file != lastFile {
			if _, err := fmt.Fprint(w, files[r.file].header); err != nil {
				return err
			}
			lastFile = r.file
		}
		if _, err := fmt.Fprint(w, files[r.file].hunks[r.hunk]); err != nil {
			return err
		}
	}
	return nil
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "git-hunk-pick: "+msg)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fatal("usage: git-hunk-pick <list|assemble INDEX...>  (diff on stdin)")
	}

	files, err := parseDiff(os.Stdin)
	if err != nil {
		fatal("reading diff: " + err.Error())
	}

	switch os.Args[1] {
	case "list":
		if err := list(os.Stdout, files); err != nil {
			fatal(err.Error())
		}
	case "assemble":
		indices := make([]int, 0, len(os.Args)-2)
		for _, a := range os.Args[2:] {
			n, err := strconv.Atoi(a)
			if err != nil {
				fatal("invalid hunk index " + strconv.Quote(a))
			}
			indices = append(indices, n)
		}
		if err := assemble(os.Stdout, files, indices); err != nil {
			fatal(err.Error())
		}
	default:
		fatal("unknown subcommand " + strconv.Quote(os.Args[1]))
	}
}
