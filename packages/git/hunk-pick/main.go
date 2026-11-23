// Command git-hunk-pick splits a unified git diff (read on stdin) into
// individually selectable hunks and reassembles a chosen subset into a valid
// patch. It backs the ga/gru/grd/gsp file picker in git.bash: `assemble` emits
// the picked hunks — grouped under each file's original header, in ascending
// diff order — as a patch that `git apply` (with `--cached` and/or `--reverse`)
// applies to stage, unstage or discard exactly those hunks, and the picker
// subcommands (picker.go) list the files, keep the picker's state as it switches
// between the files list and one file's hunks, and print the final command.
// paths and quote (paths.go) back git.bash's other file pickers: they list
// the paths each one picks from, and quote the picked ones for its command.
// tree and tree-quote (tree.go) do the same for the log picker's file step,
// which shows a commit's files as a tree.
//
// Only whole hunks are ever emitted, each one's lines as git diff wrote them,
// so the reconstructed patch is valid. Its line numbers are git diff's only in
// the preview's patch: the one the picker's command applies (assemble --sum)
// moves each hunk's numbers past the hunks left out before it, which git apply
// would not account for (see rebase). Files with no hunks (binary patches,
// mode-only or pure-rename changes) and combined ("@@@") merge diffs carry
// nothing selectable and are skipped.
//
// Usage:
//
//	git-hunk-pick list                          <diff   # INDEX<TAB>LABEL per hunk, 1-based
//	git-hunk-pick assemble [--sum SUM] INDEX... <diff   # patch of those hunks
//	git-hunk-pick files|key|load|hint|finalize SD ...   # the file picker (picker.go)
//	git-hunk-pick paths KIND [REV]                      # a kind's paths, NUL-separated (paths.go)
//	git-hunk-pick quote [PREFIX]                <picked # the picked paths as shell words
//	git-hunk-pick tree KIND REV                         # a revision's paths as tree rows (tree.go)
//	git-hunk-pick tree-quote KIND REV [PREFIX]  <picked # the picked rows' paths as shell words
//
// With --sum, assemble refuses (exit 1, no output) unless the hunks it would
// print have that digest (patchSum, of them as git diff wrote them): the
// picker's command passes the digest of the hunks as they were picked, so it
// never applies hunks that changed since. That command pipes the patch to git
// apply, so with --sum each hunk also gets the line numbers rebase gives it.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
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
	// git C-quotes a path it can't print raw ("b/caf\303\251.txt" under the
	// default core.quotePath); label the hunk with the name it stands for.
	if strings.HasPrefix(rest, `"`) {
		if u, err := strconv.Unquote(rest); err == nil {
			rest = u
		}
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

// labels returns one "path @@-header" label per hunk, in diff order.
func labels(files []fileDiff) []string {
	var out []string
	for _, f := range files {
		for _, h := range f.hunks {
			out = append(out, f.path+" "+hunkLabel(h))
		}
	}
	return out
}

// list writes one "INDEX<TAB>path @@-header" line per hunk, indices 1-based in
// diff order, for fzf to present (field 2..) and return (field 1 = index). It
// returns the first write error, if any.
func list(w io.Writer, files []fileDiff) error {
	for i, l := range labels(files) {
		if _, err := fmt.Fprintf(w, "%d\t%s\n", i+1, l); err != nil {
			return err
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
// requires), each file's header emitted once before its first kept hunk, and
// each hunk as git diff wrote it.
func assemble(w io.Writer, files []fileDiff, indices []int) error {
	return emit(w, files, indices, false)
}

// rebase writes assemble's patch for git apply, with each hunk's line numbers
// made to hold for the hunks picked. Without context, git apply finds a hunk
// by its start line, in the file as the hunks before it have left it: the new
// start applying forward (stage, a stash's tree), the old one in reverse
// (unstage, discard, a stash leaving the worktree); and it puts a hunk that
// only adds lines at that line as is. git diff counted every hunk before it, so
// each one left out shifts it by the lines that one adds (net of those it
// removes): forward, where they were never applied, the new start loses them;
// in reverse, where they stay, the old start gains them. Each start is read in
// its own direction only, but for a 0, the top of the file, which only a
// file's first hunk can have (git keeps hunks an unchanged line apart): so the
// one patch applies both ways, as git-stash-hunks applies it. A hunk with no
// hunk left out before it stays as git wrote it.
func rebase(w io.Writer, files []fileDiff, indices []int) error {
	return emit(w, files, indices, true)
}

// emit writes the hunks at the 1-based indices as assemble does; rebased, with
// the line numbers rebase gives them.
func emit(w io.Writer, files []fileDiff, indices []int, rebased bool) error {
	refs := flatten(files)
	keep := make([]bool, len(refs))
	for _, n := range indices {
		if n < 1 || n > len(refs) {
			return fmt.Errorf("hunk index %d out of range (have %d)", n, len(refs))
		}
		keep[n-1] = true
	}

	file, wrote, shift := -1, false, 0
	for i, r := range refs {
		if r.file != file {
			file, wrote, shift = r.file, false, 0
		}
		hunk := files[r.file].hunks[r.hunk]
		var s span
		var end int
		if rebased {
			var ok bool
			if s, end, ok = spanOf(hunk); !ok {
				return fmt.Errorf("unreadable hunk header %q", hunkLabel(hunk))
			}
		}
		if !keep[i] {
			shift += s.d - s.b // (0 unless rebased)
			continue
		}
		if !wrote {
			if _, err := fmt.Fprint(w, files[r.file].header); err != nil {
				return err
			}
			wrote = true
		}
		if shift != 0 {
			hunk = withSpan(hunk, end, span{s.a + shift, s.b, s.c - shift, s.d})
		}
		if _, err := fmt.Fprint(w, hunk); err != nil {
			return err
		}
	}
	return nil
}

// span is a hunk's line ranges as its "@@ -a,b +c,d @@" line has them: from
// line a, b lines, to line c, d lines (a count left out is 1; with a count of
// 0, the start is the line the hunk comes after).
type span struct{ a, b, c, d int }

var spanLine = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

// spanOf reads a hunk's span, and where on its first line the ranges end.
func spanOf(hunk string) (span, int, bool) {
	m := spanLine.FindStringSubmatch(hunk)
	if m == nil {
		return span{}, 0, false
	}
	num := func(v string) int {
		if v == "" {
			return 1
		}
		n, _ := strconv.Atoi(v)
		return n
	}
	return span{num(m[1]), num(m[2]), num(m[3]), num(m[4])}, len(m[0]), true
}

// withSpan is the hunk with s for the ranges its first line ends at end, the
// rest of that line (git's function context) and the lines below kept, and a
// count of 1 left out as git leaves it out.
func withSpan(hunk string, end int, s span) string {
	rng := func(start, count int) string {
		if count == 1 {
			return strconv.Itoa(start)
		}
		return strconv.Itoa(start) + "," + strconv.Itoa(count)
	}
	return "@@ -" + rng(s.a, s.b) + " +" + rng(s.c, s.d) + " @@" + hunk[end:]
}

// patchSum is the digest assemble --sum checks: the first 12 hex digits of the
// patch's SHA-256, plenty to tell the picked hunks from changed ones.
func patchSum(patch []byte) string {
	s := sha256.Sum256(patch)
	return hex.EncodeToString(s[:6])
}

// pick is assemble --sum: it writes the patch of the hunks at indices, for git
// apply (see rebase), only if they have digest sum, and else nothing; with no
// sum (the preview's), any hunks, as git diff wrote them.
func pick(w io.Writer, files []fileDiff, indices []int, sum string) error {
	var b bytes.Buffer
	err := assemble(&b, files, indices)
	if sum != "" && (err != nil || patchSum(b.Bytes()) != sum) {
		var paths []string
		for _, f := range files {
			paths = append(paths, f.path)
		}
		if len(paths) == 0 {
			return errors.New("the picked hunks are gone (the file changed since the pick); pick again")
		}
		return errors.New(strings.Join(paths, " ") + " changed since its hunks were picked; pick again")
	}
	if err != nil {
		return err
	}
	if sum != "" {
		b.Reset()
		if err := rebase(&b, files, indices); err != nil {
			return err
		}
	}
	_, err = w.Write(b.Bytes())
	return err
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "git-hunk-pick: "+msg)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fatal("usage: git-hunk-pick <list|assemble [--sum SUM] INDEX...>  (diff on stdin), <files|key|load|hint|finalize> SD ..., paths KIND [REV], quote [PREFIX], tree KIND REV, tree-quote KIND REV [PREFIX], log-rows COLUMNS, or path-rows KIND COLUMNS")
	}

	switch os.Args[1] {
	case "files", "key", "load", "hint", "finalize":
		if err := runPicker(os.Args[1], os.Args[2:], os.Stdout); err != nil {
			fatal(err.Error())
		}
		return
	case "paths", "quote":
		if err := runPaths(os.Args[1], os.Args[2:], os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
		return
	case "tree", "tree-quote":
		if err := runTree(os.Args[1], os.Args[2:], runGit, os.Stdin, os.Stdout); err != nil {
			fatal(err.Error())
		}
		return
	case "log-rows", "path-rows":
		if err := runRows(os.Args[1], os.Args[2:], os.Stdout); err != nil {
			fatal(err.Error())
		}
		return
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
		args, sum := os.Args[2:], ""
		if len(args) > 1 && args[0] == "--sum" {
			args, sum = args[2:], args[1]
		}
		indices := make([]int, 0, len(args))
		for _, a := range args {
			n, err := strconv.Atoi(a)
			if err != nil {
				fatal("invalid hunk index " + strconv.Quote(a))
			}
			indices = append(indices, n)
		}
		if err := pick(os.Stdout, files, indices, sum); err != nil {
			fatal(err.Error())
		}
	default:
		fatal("unknown subcommand " + strconv.Quote(os.Args[1]))
	}
}
