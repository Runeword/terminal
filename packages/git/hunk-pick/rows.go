package main

// The log and diff pickers (__git_log and __git_diff in
// .config/shell/functions/git.bash) lay out their rows alike: a commit's or a
// changed path's number from 1, right-aligned to the widest, its change, what
// it is, then its author and date flush right, with no colour of their own,
// so that fzf shows and highlights them as the rest of the row. log-rows
// prints the log picker's rows, a line each, and path-rows the diff pickers',
// NUL-terminated for fzf --read0. Their fields are 0x1f-separated, in the
// order the pickers' fzf options read them (see there).
//
// A change is + for a commit that only adds files or for a new path, - for a
// commit that only deletes some or for a deleted path, ~ otherwise, as delta
// labels a file's, in bold green, red or blue. A date is how long ago, as git
// words it (23 minutes ago), when that is less than an hour, and the local
// date and time otherwise, the year in two digits (26-10-24 14:30).
//
// A commit's row (log-rows COLUMNS):
//
//	NUMBER 0x1f AUTHOR, DATE 0x1f HASH 0x1f SUBJECT 0x1f HASH FULL-SUBJECT 0x1f CHANGE
//
// git log prints each commit's line (logFormat), then its files' statuses,
// which give its change. A subject that starts with the verb its change
// stands for, as auto-commit writes them (Add, Delete or Remove, Update),
// loses it. git pads the subject, or cuts it, up to column COLUMNS - 7 less
// the number's width, and adds a space, so that a row is as wide as fzf's
// list: COLUMNS less its pointer, marker and scrollbar columns, the change's
// two, and the number and its space. git counts that column from the start of
// the line, so it prints the author and date first, and fzf shows them last:
// the subject then ends where they leave it room. git prints the date and
// time, 14 columns wide, and at the end of the line the commit's time in
// seconds and how long ago that was, which goes in their place for a commit
// of the last hour. The room the verb or the shorter date leaves goes back to
// the subject: as spaces where git padded it, or as more of it where git cut
// it short. A subject cut short that holds more than ASCII keeps its verb,
// and gets the date's room as spaces after git's cut: its count of runes
// isn't its width. The numbers are as wide as the count of commits, which git
// rev-list gives first. HASH FULL-SUBJECT is git log --oneline's line, which
// fzf doesn't show. A line whose subject holds a 0x1f goes out as git printed
// it, its fields unknown.
//
// A path's row (path-rows KIND COLUMNS, run from the repo root, as paths is):
//
//	PATH 0x1f CHANGE 0x1f PADDING AUTHOR, DATE 0x1f NUMBER
//
// PATH is the entry of the kind's list (see paths) as is, so that fzf hands
// it on whatever it holds; CHANGE is gdc's (staged) staged change, gdd's
// (unstaged) unstaged one and gda's (changed) the file's against HEAD, as git
// status lists them. git status leaves out the untracked files (-uno: the
// list's own search found them, and a second one would walk the whole work
// tree again), so a path it doesn't list is new, and so is one in gdd's list
// that it lists with no unstaged change (git rm --cached). AUTHOR is the name
// git will commit the change under (user.name): git keeps none for a change
// not committed. DATE is when the file was last saved; a deleted file has
// none. PADDING ends the author and date at column COLUMNS - 3, the width of
// fzf's list, as a commit's row ends.

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// The changes' badges, each two columns wide.
const (
	addBadge    = "\x1b[1;38;2;47;143;83m+" + colorReset + " "
	deleteBadge = "\x1b[1;38;2;168;77;95m-" + colorReset + " "
	updateBadge = "\x1b[1;38;2;58;93;153m~" + colorReset + " "
	noBadge     = "  "
)

// changeBadge returns the badge of a status letter: A (added) or ? (not
// tracked) +, D (deleted) -, any other ~.
func changeBadge(c byte) string {
	switch c {
	case 'A', '?':
		return addBadge
	case 'D':
		return deleteBadge
	}
	return updateBadge
}

// pathChange returns the badge of a path in the list of kind, from its git
// status: porcelain's XY, ?? for a path git status doesn't list.
func pathChange(kind, xy string) string {
	x, y := xy[0], xy[1]
	switch kind {
	case "staged":
		return changeBadge(x)
	case "unstaged":
		if y == ' ' {
			return addBadge
		}
		return changeBadge(y)
	}
	switch {
	case y == 'D':
		return deleteBadge
	case x == 'A':
		return addBadge
	case y == ' ':
		return changeBadge(x)
	}
	return changeBadge(y)
}

// statusOf maps the paths in the output of git status --porcelain -z
// --no-renames to their XY.
func statusOf(out string) map[string]string {
	entries := splitList(out)
	status := make(map[string]string, len(entries))
	for _, e := range entries {
		if len(e) > 3 {
			status[e[3:]] = e[:2]
		}
	}
	return status
}

// savedAt words when a file was last saved, at now (Unix seconds): its
// seconds, or its minutes rounded as git rounds them, ago under an hour, else
// mtime's date and time.
func savedAt(mtime time.Time, now int64) string {
	switch a := now - mtime.Unix(); {
	case a == 1:
		return "1 second ago"
	case a >= 0 && a < 90:
		return strconv.FormatInt(a, 10) + " seconds ago"
	case a >= 0 && a < 3600:
		return strconv.FormatInt((a+30)/60, 10) + " minutes ago"
	}
	return mtime.Format("06-01-02 15:04")
}

// pathRows returns the rows of paths, the list of kind in its order (see the
// top of the file). status is git status's (statusOf), author the user.name,
// saved a path's last save if it is there, now Unix seconds and cols the
// terminal's width.
func pathRows(paths []string, kind string, status map[string]string, author string, saved func(string) (time.Time, bool), now int64, cols int) string {
	width := len(strconv.Itoa(len(paths)))
	var b strings.Builder
	for i, p := range paths {
		xy, listed := status[p]
		if !listed {
			xy = "??"
		}
		by := author
		if mtime, there := saved(p); there {
			if by != "" {
				by += ", "
			}
			by += savedAt(mtime, now)
		}
		pad := max(cols-width-6-utf8.RuneCountInString(p)-utf8.RuneCountInString(by), 1)
		fmt.Fprintf(&b, "%s\x1f%s\x1f%s%s\x1f%*d\x00", p, pathChange(kind, xy), strings.Repeat(" ", pad), by, width, i+1)
	}
	return b.String()
}

// lastSaved returns when the file at p, a symlink itself and not what it
// points to, was last saved, if it is there.
func lastSaved(p string) (time.Time, bool) {
	fi, err := os.Lstat(p)
	if err != nil {
		return time.Time{}, false
	}
	return fi.ModTime(), true
}

// logFormat is git log's format for a commit's line, its subject padded or cut
// up to column col: a 0x1e, then the author and date, the hash, the subject
// between spaces, git log --oneline's line, the commit's time in seconds and
// how long ago that was.
func logFormat(col int) string {
	return "%x1e%an, %ad%x1f%h%x1f %<|(" + strconv.Itoa(col) + ",trunc)%s %x1f%h %s%x1f%at%x1f%ar"
}

// logArgs are the arguments of the git log that logRows reads: each commit's
// line, then its files' statuses, a merge's against its first parent.
func logArgs(col int) []string {
	return []string{
		"log", "--no-renames", "--diff-merges=first-parent", "--name-status",
		"--date=format-local:%y-%m-%d %H:%M", "--format=" + logFormat(col),
	}
}

// pad returns n spaces, none for n < 1.
func pad(n int) string { return strings.Repeat(" ", max(n, 0)) }

// printableASCII reports whether s holds printable ASCII only.
func printableASCII(s string) bool {
	for i := range len(s) {
		if s[i] < ' ' || s[i] > '~' {
			return false
		}
	}
	return true
}

// logRow returns a commit's row but its number, and its badge, from the
// commit's line without its 0x1e and whether its files' statuses add,
// delete or change others (see the top of the file); now is Unix seconds.
func logRow(line string, adds, deletes, others bool, now int64) (row, badge string) {
	var verbs []string
	switch {
	case adds && !deletes && !others:
		badge, verbs = addBadge, []string{"Add "}
	case deletes && !adds && !others:
		badge, verbs = deleteBadge, []string{"Delete ", "Remove "}
	case adds || deletes || others:
		badge, verbs = updateBadge, []string{"Update "}
	default:
		badge = noBadge
	}
	f := strings.Split(line, "\x1f")
	if len(f) != 6 {
		return line, badge
	}
	by, hash, oneline := f[0], f[1], f[3]
	var full, s string
	if len(oneline) > len(hash)+1 {
		full = oneline[len(hash)+1:]
	}
	if len(f[2]) >= 2 {
		s = f[2][1 : len(f[2])-1]
	}
	t := full
	for _, v := range verbs {
		if rest, ok := strings.CutPrefix(full, v); ok {
			t = rest
			break
		}
	}
	room := 0
	if at, err := strconv.ParseInt(f[4], 10, 64); err == nil && at <= now && now-at < 3600 {
		room = 14 - utf8.RuneCountInString(f[5])
		by = by[:max(len(by)-14, 0)] + f[5]
	}
	if t != full || room != 0 {
		room += utf8.RuneCountInString(s)
		switch {
		case strings.HasPrefix(s, full):
			s = t + pad(room-utf8.RuneCountInString(t))
		case printableASCII(full) && room > 2:
			if len(t) > room {
				s = t[:room-2] + ".."
			} else {
				s = t + pad(room-len(t))
			}
		default:
			s += pad(room - utf8.RuneCountInString(s))
		}
	}
	return by + "\x1f" + hash + "\x1f " + s + " \x1f" + oneline, badge
}

// logRows reads the output of git log (logArgs) on r and writes a row per
// commit on w, numbered from 1 and right-aligned to width digits; now is Unix
// seconds.
func logRows(r io.Reader, w io.Writer, width int, now int64) error {
	in, out := bufio.NewReader(r), bufio.NewWriter(w)
	var line string
	var adds, deletes, others bool
	n := 0
	put := func() error {
		if line == "" {
			return nil
		}
		row, badge := logRow(line, adds, deletes, others, now)
		n++
		_, err := fmt.Fprintf(out, "%*d\x1f%s\x1f%s\n", width, n, row, badge)
		return err
	}
	for {
		s, err := in.ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		s = strings.TrimSuffix(s, "\n")
		switch {
		case strings.HasPrefix(s, "\x1e"):
			if perr := put(); perr != nil {
				return perr
			}
			line, adds, deletes, others = s[1:], false, false, false
		case strings.HasPrefix(s, "A\t"):
			adds = true
		case strings.HasPrefix(s, "D\t"):
			deletes = true
		case s != "" && s[0] >= 'A' && s[0] <= 'Z':
			others = true
		}
		if err != nil {
			break
		}
	}
	if err := put(); err != nil {
		return err
	}
	return out.Flush()
}

// writeLogRows writes the log picker's rows for a terminal cols wide, as git
// log prints the commits, from the current directory.
func writeLogRows(w io.Writer, cols int) error {
	// No commit to count leaves the numbers no width, and git log fails.
	width := 0
	if count, err := exec.Command("git", "rev-list", "--count", "HEAD").Output(); err == nil {
		width = len(strings.TrimSpace(string(count)))
	}
	cmd := exec.Command("git", logArgs(cols-7-width)...)
	cmd.Stderr = os.Stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	if err := logRows(stdout, w, width, time.Now().Unix()); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("git log: %w", err)
	}
	return nil
}

// writePathRows writes the diff pickers' rows of the list of kind for a
// terminal cols wide, from the repo root.
func writePathRows(w io.Writer, kind string, cols int) error {
	if kind != "staged" && kind != "unstaged" && kind != "changed" {
		return fmt.Errorf("path-rows lists staged, unstaged or changed paths, not %s", kind)
	}
	paths, err := listPaths(runGit, kind, "")
	if err != nil {
		return err
	}
	status, err := runGit("--no-optional-locks", "status", "--porcelain", "-z", "--no-renames", "--untracked-files=no")
	if err != nil {
		return err
	}
	// No user.name (git config fails) leaves the rows no author.
	author := ""
	if out, err := exec.Command("git", "config", "user.name").Output(); err == nil {
		author, _, _ = strings.Cut(string(out), "\n")
	}
	_, err = io.WriteString(w, pathRows(paths, kind, statusOf(status), author, lastSaved, time.Now().Unix(), cols))
	return err
}

// runRows dispatches log-rows, which writes the log picker's rows, and
// path-rows, which writes the diff pickers' rows of a kind's list.
func runRows(cmd string, args []string, w io.Writer) error {
	switch cmd {
	case "log-rows":
		if len(args) != 1 {
			return errors.New("usage: git-hunk-pick log-rows COLUMNS")
		}
		cols, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("log-rows: COLUMNS: %w", err)
		}
		return writeLogRows(w, cols)
	case "path-rows":
		if len(args) != 2 {
			return errors.New("usage: git-hunk-pick path-rows KIND COLUMNS  (from the repo root)")
		}
		cols, err := strconv.Atoi(args[1])
		if err != nil {
			return fmt.Errorf("path-rows: COLUMNS: %w", err)
		}
		return writePathRows(w, args[0], cols)
	}
	return fmt.Errorf("unknown subcommand %q", cmd)
}
