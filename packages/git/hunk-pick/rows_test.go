package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// TestPathChange gives each kind's change: gdc's the staged one, gdd's the
// unstaged one (a path git rm --cached left on disk is new to it), gda's the
// file's against HEAD; a path git status doesn't list is new.
func TestPathChange(t *testing.T) {
	tests := []struct {
		kind, xy, want string
	}{
		{"staged", "M ", updateBadge},
		{"staged", "A ", addBadge},
		{"staged", "D ", deleteBadge},
		{"staged", "MM", updateBadge},
		{"staged", "??", addBadge},
		{"unstaged", " M", updateBadge},
		{"unstaged", " D", deleteBadge},
		{"unstaged", "MM", updateBadge},
		{"unstaged", "D ", addBadge},
		{"unstaged", "??", addBadge},
		{"changed", " M", updateBadge},
		{"changed", "M ", updateBadge},
		{"changed", "A ", addBadge},
		{"changed", "AM", addBadge},
		{"changed", "AD", deleteBadge},
		{"changed", "MD", deleteBadge},
		{"changed", "D ", deleteBadge},
		{"changed", "??", addBadge},
	}
	for _, tt := range tests {
		t.Run(tt.kind+" "+tt.xy, func(t *testing.T) {
			if got := pathChange(tt.kind, tt.xy); got != tt.want {
				t.Errorf("pathChange(%q, %q) = %q, want %q", tt.kind, tt.xy, got, tt.want)
			}
		})
	}
}

// TestSavedAt words a save under an hour ago in git's words, its minutes
// rounded as git rounds them, and an older or a future one by its date.
func TestSavedAt(t *testing.T) {
	const now = 1_000_000 // 1970-01-12 13:46:40 UTC
	tests := []struct {
		ago  int64
		want string
	}{
		{0, "0 seconds ago"},
		{1, "1 second ago"},
		{89, "89 seconds ago"},
		{90, "2 minutes ago"},
		{149, "2 minutes ago"},
		{150, "3 minutes ago"},
		{3599, "60 minutes ago"},
		{3600, "70-01-12 12:46"},
		{-1, "70-01-12 13:46"},
	}
	for _, tt := range tests {
		t.Run(strconv.FormatInt(tt.ago, 10), func(t *testing.T) {
			if got := savedAt(time.Unix(now-tt.ago, 0).UTC(), now); got != tt.want {
				t.Errorf("savedAt(%d s ago) = %q, want %q", tt.ago, got, tt.want)
			}
		})
	}
}

// TestPathRows lays out a path's row: the path, its change, the author and
// date flush right at column COLUMNS - 3 (one space at least, counted in
// runes), and the number, right-aligned.
func TestPathRows(t *testing.T) {
	const now = 1_761_400_000
	at := func(sec int64) time.Time { return time.Unix(sec, 0).UTC() }
	tests := []struct {
		name   string
		paths  []string
		status map[string]string
		author string
		saved  map[string]time.Time // missing: the file is gone
		cols   int
		want   []string
	}{
		{
			"ten staged paths: a deleted one, a changed one, new ones",
			[]string{" a", "b", "c", "d", "e", "f", "g", "h", "i 1", "j"},
			map[string]string{" a": "D ", "b": "M "},
			"u",
			map[string]time.Time{
				"b": at(0), "c": at(0), "d": at(0), "e": at(0), "f": at(0),
				"g": at(0), "h": at(0), "i 1": at(now - 100), "j": at(0),
			},
			40,
			[]string{
				" a\x1f" + deleteBadge + "\x1f" + pad(29) + "u\x1f 1",
				"b\x1f" + updateBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 2",
				"c\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 3",
				"d\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 4",
				"e\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 5",
				"f\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 6",
				"g\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 7",
				"h\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f 8",
				"i 1\x1f" + addBadge + "\x1f" + pad(13) + "u, 2 minutes ago\x1f 9",
				"j\x1f" + addBadge + "\x1f" + pad(14) + "u, 70-01-01 00:00\x1f10",
			},
		},
		{
			"no author and a deleted file: nothing after the padding",
			[]string{" a"},
			map[string]string{" a": " D"},
			"",
			nil,
			40,
			[]string{" a\x1f" + updateBadge + "\x1f" + pad(31) + "\x1f1"},
		},
		{
			"a name and an author past ASCII, counted in runes",
			[]string{"naïve.txt"},
			map[string]string{"naïve.txt": "M "},
			"Zoë",
			map[string]time.Time{"naïve.txt": at(0)},
			40,
			[]string{"naïve.txt\x1f" + updateBadge + "\x1f" + pad(5) + "Zoë, 70-01-01 00:00\x1f1"},
		},
		{
			"no room: one space",
			[]string{"long-name.txt"},
			map[string]string{"long-name.txt": "M "},
			"u",
			map[string]time.Time{"long-name.txt": at(0)},
			10,
			[]string{"long-name.txt\x1f" + updateBadge + "\x1f u, 70-01-01 00:00\x1f1"},
		},
		{"no paths", nil, nil, "u", nil, 40, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			saved := func(p string) (time.Time, bool) {
				mtime, there := tt.saved[p]
				return mtime, there
			}
			got := splitList(pathRows(tt.paths, "staged", tt.status, tt.author, saved, now, tt.cols))
			if strings.Join(got, "\n") != strings.Join(tt.want, "\n") {
				t.Errorf("pathRows =\n%q\nwant\n%q", got, tt.want)
			}
		})
	}
}

// TestLogRows turns git log's lines into rows: numbered, the change from the
// files' statuses, the verb it stands for dropped, how long ago for a commit
// of the last hour, the room either leaves given back to the subject.
func TestLogRows(t *testing.T) {
	const now = 1_761_400_000
	ago := func(s int64) string { return strconv.FormatInt(now-s, 10) }
	tests := []struct {
		name  string
		width int
		log   string
		want  []string
	}{
		{
			"a commit of the last hour that deletes files, and an older one with none",
			2,
			"\x1ea, 26-10-25 21:42\x1fabc\x1f Delete f \x1fabc Delete f\x1f" + ago(120) + "\x1f2 minutes ago\n\nD\tf\nD\tg\n" +
				"\x1eb, 70-01-01 00:00\x1fdef\x1f x \x1fdef x\x1f0\x1f56 years ago\n",
			[]string{
				" 1\x1fa, 2 minutes ago\x1fabc\x1f f" + pad(9) + "\x1fabc Delete f\x1f" + deleteBadge,
				" 2\x1fb, 70-01-01 00:00\x1fdef\x1f x \x1fdef x\x1f" + noBadge,
			},
		},
		{
			"the verb each change stands for, and one it doesn't",
			1,
			"\x1en, 23-11-14 22:13\x1fh1\x1f Add x      \x1fh1 Add x\x1f1700000000\x1f2 years ago\n\nA\tx\n" +
				"\x1en, 23-11-14 22:13\x1fh2\x1f Add y      \x1fh2 Add y\x1f1700000000\x1f2 years ago\n\nA\ty\nM\tz\n" +
				"\x1en, 23-11-14 22:13\x1fh3\x1f Update z   \x1fh3 Update z\x1f1700000000\x1f2 years ago\n\nM\tz\n" +
				"\x1en, 23-11-14 22:13\x1fh4\x1f Remove w   \x1fh4 Remove w\x1f1700000000\x1f2 years ago\n\nD\tw\n",
			[]string{
				"1\x1fn, 23-11-14 22:13\x1fh1\x1f x" + pad(10) + "\x1fh1 Add x\x1f" + addBadge,
				"2\x1fn, 23-11-14 22:13\x1fh2\x1f Add y      \x1fh2 Add y\x1f" + updateBadge,
				"3\x1fn, 23-11-14 22:13\x1fh3\x1f z" + pad(10) + "\x1fh3 Update z\x1f" + updateBadge,
				"4\x1fn, 23-11-14 22:13\x1fh4\x1f w" + pad(10) + "\x1fh4 Remove w\x1f" + deleteBadge,
			},
		},
		{
			"subjects git cut short: ASCII cut again past the verb, the rest kept as cut",
			0,
			"\x1en, 23-11-14 22:13\x1fh1\x1f Update th.. \x1fh1 Update the long subject here\x1f1700000000\x1f2 years ago\n\nM\tc\n" +
				"\x1en, 26-10-25 21:42\x1fh2\x1f Update café ü.. \x1fh2 Update café ünïcödé long\x1f" + ago(300) + "\x1f5 minutes ago\n\nM\tc\n",
			[]string{
				"1\x1fn, 23-11-14 22:13\x1fh1\x1f the long .. \x1fh1 Update the long subject here\x1f" + updateBadge,
				"2\x1fn, 5 minutes ago\x1fh2\x1f Update café ü..  \x1fh2 Update café ünïcödé long\x1f" + updateBadge,
			},
		},
		{
			"a subject holding a 0x1f goes out as git printed it",
			0,
			"\x1en, 23-11-14 22:13\x1fh\x1f odd\x1fsub \x1fh odd\x1fsub\x1f1700000000\x1f2 years ago\n\nM\tc\n",
			[]string{"1\x1fn, 23-11-14 22:13\x1fh\x1f odd\x1fsub \x1fh odd\x1fsub\x1f1700000000\x1f2 years ago\x1f" + updateBadge},
		},
		{"no commits", 0, "", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			if err := logRows(strings.NewReader(tt.log), &b, tt.width, now); err != nil {
				t.Fatal(err)
			}
			got := strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n")
			if b.Len() == 0 {
				got = nil
			}
			if strings.Join(got, "\n") != strings.Join(tt.want, "\n") {
				t.Errorf("logRows =\n%q\nwant\n%q", got, tt.want)
			}
		})
	}
}

// shownWidth is the width fzf shows a row at, its escapes dropped and its
// 0x1f drawn as nothing: the log picker's {1} {6}{3}{4}{2}, the diff
// pickers' {-1} {-3}{..-4}{-2}.
func shownWidth(row string, log bool) int {
	f := strings.Split(regexp.MustCompile("\x1b\\[[0-9;]*m").ReplaceAllString(row, ""), "\x1f")
	shown := f[3] + " " + f[1] + f[0] + f[2]
	if log {
		shown = f[0] + " " + f[5] + f[2] + f[3] + f[1]
	}
	return utf8.RuneCountInString(shown)
}

// TestRowsRealGit runs log-rows and path-rows in a real repo: each row as wide
// as fzf's list (COLUMNS - 3), the changes, verbs and dates from git.
func TestRowsRealGit(t *testing.T) {
	repo := t.TempDir()
	t.Setenv("HOME", repo)
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	for _, v := range []string{"GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"} {
		t.Setenv(v, "ann")
	}
	for _, v := range []string{"GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"} {
		t.Setenv(v, "a@x")
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) {
		t.Helper()
		if _, err := runGit(args...); err != nil {
			t.Fatalf("git %s: %v", strings.Join(args, " "), err)
		}
	}
	write := func(name, s string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(repo, name), []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().Unix()
	// commit commits every change in the work tree, made at at.
	commit := func(at int64, msg string) {
		t.Helper()
		date := "@" + strconv.FormatInt(at, 10)
		t.Setenv("GIT_AUTHOR_DATE", date)
		t.Setenv("GIT_COMMITTER_DATE", date)
		git("add", "-A")
		git("commit", "-qm", msg)
	}

	git("init", "-q")
	git("config", "user.name", "u")
	write("a.txt", "1\n")
	write("b.txt", "1\n")
	commit(1_700_000_000, "Add a.txt and b.txt")
	write("a.txt", "2\n")
	commit(1_700_000_100, "Update a.txt")
	if err := os.Remove("b.txt"); err != nil {
		t.Fatal(err)
	}
	commit(1_700_000_200, "Delete b.txt")
	write("a.txt", "3\n")
	write("c.txt", "1\n")
	commit(now-600, "Add c.txt, change a.txt")

	t.Run("log-rows", func(t *testing.T) {
		var b strings.Builder
		if err := runRows("log-rows", []string{"60"}, &b); err != nil {
			t.Fatal(err)
		}
		rows := strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n")
		want := []struct {
			badge, subject, date string
		}{
			{updateBadge, "Add c.txt, change a.txt", "10 minutes ago"},
			{deleteBadge, "b.txt", ""},
			{updateBadge, "a.txt", ""},
			{addBadge, "a.txt and b.txt", ""},
		}
		if len(rows) != len(want) {
			t.Fatalf("got %d rows, want %d:\n%q", len(rows), len(want), rows)
		}
		for i, row := range rows {
			f := strings.Split(row, "\x1f")
			if len(f) != 6 || f[0] != strconv.Itoa(i+1) || f[5] != want[i].badge || strings.TrimSpace(f[3]) != want[i].subject {
				t.Errorf("row %d = %q, want number %d, subject %q and badge %q", i+1, row, i+1, want[i].subject, want[i].badge)
			}
			if want[i].date != "" && f[1] != "ann, "+want[i].date {
				t.Errorf("row %d's author and date = %q, want ann, %s", i+1, f[1], want[i].date)
			}
			if w := shownWidth(row, true); w != 57 {
				t.Errorf("row %d is %d columns wide, want 57 (COLUMNS - 3): %q", i+1, w, row)
			}
		}
	})

	t.Run("path-rows", func(t *testing.T) {
		write("a.txt", "4\n") // changed, not staged
		write("d.txt", "1\n")
		git("add", "d.txt")   // new, staged
		write("e.txt", "1\n") // untracked
		for name, ago := range map[string]int64{"a.txt": 600, "d.txt": 100, "e.txt": 1000} {
			mtime := time.Unix(now-ago, 0)
			if err := os.Chtimes(name, mtime, mtime); err != nil {
				t.Fatal(err)
			}
		}
		var b strings.Builder
		if err := runRows("path-rows", []string{"changed", "50"}, &b); err != nil {
			t.Fatal(err)
		}
		rows := splitList(b.String())
		want := []struct {
			path, badge, by string
		}{
			{"a.txt", updateBadge, "u, 10 minutes ago"},
			{"d.txt", addBadge, "u, 2 minutes ago"},
			{"e.txt", addBadge, "u, 17 minutes ago"},
		}
		if len(rows) != len(want) {
			t.Fatalf("got %d rows, want %d:\n%q", len(rows), len(want), rows)
		}
		for i, row := range rows {
			f := strings.Split(row, "\x1f")
			if len(f) != 4 || f[0] != want[i].path || f[1] != want[i].badge || strings.TrimSpace(f[2]) != want[i].by || f[3] != strconv.Itoa(i+1) {
				t.Errorf("row %d = %q, want %s, its badge %q and %s", i+1, row, want[i].path, want[i].badge, want[i].by)
			}
			if w := shownWidth(row, false); w != 47 {
				t.Errorf("row %d is %d columns wide, want 47 (COLUMNS - 3): %q", i+1, w, row)
			}
		}
	})
}
