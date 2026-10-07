package main

import (
	"errors"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// TestMain lets the test binary stand in for git-hunk-pick in the commands
// finalize prints (see TestFinalizedCommand).
func TestMain(m *testing.M) {
	if filepath.Base(os.Args[0]) == "git-hunk-pick" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fooDiff gives foo.txt two hunks; every other path has no diff.
var fooDiff = fooHeader + fooHunk1 + fooHunk2

// fakeGit answers the picker's git calls from a table keyed by the joined
// arguments; anything else prints nothing.
func fakeGit(out map[string]string) func(args ...string) (string, error) {
	return func(args ...string) (string, error) { return out[strings.Join(args, " ")], nil }
}

// TestPickerKeyAndLoad presses one key, then runs load as fzf would once the
// reload lands. The files list is bar.txt, foo.txt.
func TestPickerKeyAndLoad(t *testing.T) {
	tests := []struct {
		name     string
		drilled  string            // the hunks list for this file is up
		state    pickerState       // state.json before the key
		query    string            // the files query saved at the drill
		env      map[string]string // FZF_SELECT_COUNT, FZF_QUERY, FZF_INPUT_STATE
		key      string
		item     string
		marked   []string // the selection file, {+f}
		sel      []int    // {+n}
		want     string   // key's actions; <dir> is the state directory
		load     string   // load's actions
		spec     string   // foo.txt's spec afterwards
		sum      string   // foo.txt's digest afterwards
		drill    string   // .drill afterwards
		accepted []string // the selection when accepted
	}{
		{name: "left edits the query", key: "left", want: "backward-char"},
		{name: "esc aborts from search mode", key: "esc", want: "abort"},
		{name: "esc leaves nav mode", key: "esc", env: map[string]string{"FZF_INPUT_STATE": "disabled"}, want: "trigger(alt-i)"},
		{name: "right on a file without hunks", key: "right", item: "new.txt"},
		{
			name: "enter on a file without hunks accepts", key: "enter", item: "new.txt",
			env: map[string]string{"FZF_SELECT_COUNT": "1"}, marked: []string{"bar.txt"},
			want: "accept", accepted: []string{"bar.txt"},
		},
		{
			name: "drill", key: "enter", item: "foo.txt",
			want: "reload-sync(cat '<dir>/.hunks')", load: "change-header(H)+first", drill: "foo.txt",
		},
		{
			name: "drill clears the query and preselects a Tab-marked file", key: "right", item: "foo.txt",
			env:    map[string]string{"FZF_SELECT_COUNT": "1", "FZF_QUERY": "fo"},
			marked: []string{"foo.txt"},
			want:   "reload-sync(cat '<dir>/.hunks')", load: "change-header(H)+change-query()+wait+select-all+first", drill: "foo.txt",
		},
		{
			name: "drill preselects the saved spec", key: "enter", item: "foo.txt",
			state: pickerState{Specs: map[string]string{"foo.txt": "2"}, Sums: map[string]string{"foo.txt": "s"}},
			want:  "reload-sync(cat '<dir>/.hunks')", load: "change-header(H)+pos(2)+select+first", spec: "2", sum: "s", drill: "foo.txt",
		},
		{name: "right in the hunks list edits the query", drilled: "foo.txt", key: "right", want: "forward-char", drill: "foo.txt"},
		{
			name: "back records a subset and its digest, restores marks and cursor", drilled: "foo.txt", key: "left",
			state: pickerState{Marks: []string{"bar.txt"}},
			env:   map[string]string{"FZF_SELECT_COUNT": "1"}, sel: []int{1},
			want: "reload-sync(cat '<dir>/.files')", load: "change-header(F)+pos(1)+select+pos(2)+select+pos(2)",
			spec: "2", sum: patchSum([]byte(fooHeader + fooHunk2)),
		},
		{
			name: "back with nothing marked drops the file and restores the query", drilled: "foo.txt", key: "esc",
			state: pickerState{
				Marks: []string{"bar.txt", "foo.txt"},
				Specs: map[string]string{"foo.txt": "1"}, Sums: map[string]string{"foo.txt": "s"},
			},
			query: "fo", env: map[string]string{"FZF_QUERY": "x"},
			want: "reload-sync(cat '<dir>/.files')",
			load: "change-header(F)+change-query()+wait+pos(1)+select+pos(2)+" +
				"track-current+transform-query(cat '<dir>/.query')+wait+untrack-current",
		},
		{
			name: "enter in the hunks list accepts as shown", drilled: "foo.txt", key: "enter",
			state: pickerState{Marks: []string{"bar.txt"}, Specs: map[string]string{"foo.txt": "1"}, Sums: map[string]string{"foo.txt": "s"}},
			env:   map[string]string{"FZF_SELECT_COUNT": "2"}, sel: []int{1, 0},
			want: "accept", spec: "ALL", drill: "foo.txt", accepted: []string{"bar.txt", "foo.txt"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			write := func(name, data string) {
				t.Helper()
				if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			write(".files", joinList([]string{"bar.txt", "foo.txt"}))
			write("sel", joinList(tt.marked))
			if tt.drilled != "" {
				files, _ := parseDiff(strings.NewReader(fooDiff))
				write(".drill", tt.drilled+"\n")
				write(".diff", fooDiff)
				write(".hunks", joinList(labels(files)))
			}
			write(".query", tt.query)
			env := map[string]string{"GFS_HEADER_FILES": "F", "GFS_HEADER_HUNKS": "H"}
			maps.Copy(env, tt.env)
			p := picker{
				dir:    dir,
				getenv: func(k string) string { return env[k] },
				git:    fakeGit(map[string]string{"diff --unified=0 -- foo.txt": fooDiff}),
			}
			if err := p.saveState(tt.state); err != nil {
				t.Fatal(err)
			}

			got, err := p.key(pickOps["stage"], tt.key, filepath.Join(dir, "sel"), tt.item, tt.sel)
			if err != nil {
				t.Fatalf("key: %v", err)
			}
			loaded, err := p.load()
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			st, _ := p.loadState()
			drill, _ := os.ReadFile(filepath.Join(dir, ".drill"))
			in := func(s string) string { return strings.ReplaceAll(s, "<dir>", dir) }
			if got != in(tt.want) {
				t.Errorf("key = %q, want %q", got, in(tt.want))
			}
			if loaded != in(tt.load) {
				t.Errorf("load = %q, want %q", loaded, in(tt.load))
			}
			if st.Specs["foo.txt"] != tt.spec || st.Sums["foo.txt"] != tt.sum {
				t.Errorf("spec, sum = %q, %q, want %q, %q", st.Specs["foo.txt"], st.Sums["foo.txt"], tt.spec, tt.sum)
			}
			if d := strings.TrimSuffix(string(drill), "\n"); d != tt.drill {
				t.Errorf(".drill = %q, want %q", d, tt.drill)
			}
			if !slices.Equal(st.Accepted, tt.accepted) {
				t.Errorf("accepted = %q, want %q", st.Accepted, tt.accepted)
			}
		})
	}
}

func TestPickerHint(t *testing.T) {
	dir := t.TempDir()
	if err := (picker{dir: dir}).saveState(pickerState{Specs: map[string]string{"a.go": "ALL", "b.go": "1 3"}}); err != nil {
		t.Fatal(err)
	}
	tests := []struct{ path, want string }{
		{"b.go", "◐ hunks: 1 3\n"},
		{"a.go", ""}, // whole: fzf's own marker shows it
		{"c.go", ""},
	}
	for _, tt := range tests {
		var b strings.Builder
		if err := runPicker("hint", []string{dir, tt.path}, &b); err != nil {
			t.Fatalf("hint %s: %v", tt.path, err)
		}
		if b.String() != tt.want {
			t.Errorf("hint %s = %q, want %q", tt.path, b.String(), tt.want)
		}
	}
}

// TestPickerDistrustsState plants in state.json what something else that can
// write it might: an fzf action queued for load, and a spec and a digest that
// would run a command once spliced in. Neither load, a drill into foo.txt nor
// finalize may pass any of it on.
func TestPickerDistrustsState(t *testing.T) {
	tests := []struct{ name, state string }{
		{"a queued action", `{"pending":{"actions":"execute-silent(touch pwned)"}}`},
		{"a spec", `{"specs":{"foo.txt":"1)+execute-silent(touch${IFS}pwned)+pos(1"},"accepted":["foo.txt"]}`},
		{"a digest", `{"specs":{"foo.txt":"1"},"sums":{"foo.txt":"0; touch pwned #"},"accepted":["foo.txt"]}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := picker{
				dir:    t.TempDir(),
				getenv: func(string) string { return "" },
				git:    fakeGit(map[string]string{"diff --unified=0 -- foo.txt": fooDiff}),
			}
			if err := os.WriteFile(p.path("state.json"), []byte(tt.state), 0o600); err != nil {
				t.Fatal(err)
			}
			var outs []string
			for _, step := range []func() (string, error){
				p.load,
				func() (string, error) { return p.key(pickOps["stage"], "enter", "", "foo.txt", nil) },
				p.load,
				func() (string, error) { return p.finalize(pickOps["stage"], "git") },
			} {
				out, _ := step()
				outs = append(outs, out)
			}
			if got := strings.Join(outs, "\n"); strings.Contains(got, "pwned") {
				t.Errorf("state.json's text came out as an action or a command:\n%s", got)
			}
		})
	}
}

// TestPickerFiles lists each op's files verbatim (git -z), sorted and
// deduplicated, and saves them for a return.
func TestPickerFiles(t *testing.T) {
	git := fakeGit(map[string]string{
		"diff --name-only -z":                     "b.txt\x00café.txt\x00",
		"diff --cached --name-only -z":            "s.txt\x00",
		"ls-files --others --exclude-standard -z": "a b.txt\x00b.txt\x00new\nline\x00",
	})
	tests := []struct{ op, want string }{
		{"stage", "a b.txt\x00b.txt\x00café.txt\x00new\nline\x00"},
		{"stash", "a b.txt\x00b.txt\x00café.txt\x00new\nline\x00"},
		{"unstage", "s.txt\x00"},
		{"discard", "b.txt\x00café.txt\x00"},
	}
	for _, tt := range tests {
		t.Run(tt.op, func(t *testing.T) {
			p := picker{dir: t.TempDir(), git: git}
			got, err := p.files(pickOps[tt.op])
			if err != nil {
				t.Fatal(err)
			}
			saved, _ := os.ReadFile(p.path(".files"))
			if got != tt.want || string(saved) != tt.want {
				t.Errorf("files = %q, saved %q, want %q", got, saved, tt.want)
			}
		})
	}
}

// TestPickerFinalize prints the command for each op from an accepted pick:
// h.txt and it's.txt are hunk subsets, all.txt was drilled with every hunk
// marked, a.txt was only Tab-marked.
func TestPickerFinalize(t *testing.T) {
	const (
		h    = "git -C . diff --unified=0 -- 'h.txt' | git-hunk-pick assemble --sum aaaaaaaaaaaa 1 3"
		it   = `git -C . diff --unified=0 -- 'it'\''s.txt' | git-hunk-pick assemble --sum bbbbbbbbbbbb 2`
		hIdx = "git -C . diff --cached --unified=0 -- 'h.txt' | git-hunk-pick assemble --sum aaaaaaaaaaaa 1 3"
	)
	tests := []struct {
		name, op string
		accepted []string
		want     string
	}{
		{"nothing accepted", "stage", nil, ""},
		{"whole files batched", "stage", []string{"a.txt", "all.txt"}, "git -C . add -- 'a.txt' 'all.txt'"},
		{"a subset re-checks its hunks", "stage", []string{"h.txt"}, h + " | git -C . apply --cached --unidiff-zero --recount"},
		{
			"whole files first, then each subset", "discard",
			[]string{"h.txt", "a.txt", "it's.txt"},
			"git -C . restore -- 'a.txt' && " + h + " | git -C . apply --reverse --unidiff-zero --recount && " +
				it + " | git -C . apply --reverse --unidiff-zero --recount",
		},
		{
			"unstage reads the index", "unstage",
			[]string{"all.txt", "h.txt"},
			"git -C . restore --staged -- 'all.txt' && " + hIdx + " | git -C . apply --cached --reverse --unidiff-zero --recount",
		},
		{"stash whole files", "stash", []string{"a.txt", "all.txt"}, "git-stash-hunks --whole 'a.txt' --whole 'all.txt' </dev/null"},
		{
			"stash subsets and whole files", "stash",
			[]string{"h.txt", "a.txt", "it's.txt"},
			"{ " + h + "; " + it + "; } | git-stash-hunks --whole 'a.txt'",
		},
		{"a name git would quote stays verbatim", "stage", []string{"café\tx\n.txt"}, "git -C . add -- 'café\tx\n.txt'"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := picker{dir: t.TempDir()}
			st := pickerState{
				Specs:    map[string]string{"h.txt": "1 3", "all.txt": "ALL", "it's.txt": "2"},
				Sums:     map[string]string{"h.txt": "aaaaaaaaaaaa", "it's.txt": "bbbbbbbbbbbb"},
				Accepted: tt.accepted,
			}
			if err := p.saveState(st); err != nil {
				t.Fatal(err)
			}
			got, err := p.finalize(pickOps[tt.op], "git -C .")
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("finalize =\n%q\nwant\n%q", got, tt.want)
			}
		})
	}
}

// TestFinalizedCommand picks the second of f.txt's two hunks through the
// bindings' calls and runs the printed command with real git: it must touch
// that hunk alone, and refuse once the file has changed so that another hunk
// sits at the picked index.
func TestFinalizedCommand(t *testing.T) {
	repo, bin := t.TempDir(), t.TempDir()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(self, filepath.Join(bin, "git-hunk-pick")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("HOME", repo)
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_SYSTEM", "/dev/null")
	for _, v := range []string{"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"} {
		t.Setenv(v, "t")
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(repo); err != nil {
		t.Fatal(err)
	}
	git := func(t *testing.T, args ...string) string {
		t.Helper()
		out, err := runGit(args...)
		if err != nil {
			t.Fatalf("git %s: %v", strings.Join(args, " "), err)
		}
		return out
	}
	writeF := func(t *testing.T, s string) {
		t.Helper()
		if err := os.WriteFile("f.txt", []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	const (
		base   = "1\n2\n3\n4\n5\n6\n7\n8\n9\n"
		edited = "ONE\n2\n3\n4\n5\n6\n7\n8\nNINE\n"
		first  = "ONE\n2\n3\n4\n5\n6\n7\n8\n9\n"  // the first hunk only
		second = "1\n2\n3\n4\n5\n6\n7\n8\nNINE\n" // the second hunk only
	)
	git(t, "init", "-q")
	writeF(t, base)
	git(t, "add", "f.txt")
	git(t, "commit", "-qm", "base")

	// pickSecond drills into f.txt, marks its second hunk and accepts, as the
	// bindings would, and returns the printed command.
	pickSecond := func(t *testing.T, op string) string {
		t.Helper()
		count := "0"
		p := picker{dir: t.TempDir(), getenv: func(k string) string {
			return map[string]string{"FZF_SELECT_COUNT": count}[k]
		}, git: runGit}
		if _, err := p.files(pickOps[op]); err != nil {
			t.Fatal(err)
		}
		if _, err := p.key(pickOps[op], "enter", "", "f.txt", nil); err != nil {
			t.Fatal(err)
		}
		if _, err := p.load(); err != nil {
			t.Fatal(err)
		}
		count = "1"
		if got, err := p.key(pickOps[op], "enter", "", "", []int{1}); err != nil || got != "accept" {
			t.Fatalf("enter in the hunks list = %q, %v", got, err)
		}
		cmd, err := p.finalize(pickOps[op], "git -C .")
		if err != nil {
			t.Fatal(err)
		}
		return cmd
	}
	run := func(t *testing.T, cmd string) error {
		out, err := exec.Command("sh", "-c", cmd).CombinedOutput()
		t.Logf("%s\n%s", cmd, out)
		return err
	}

	tests := []struct {
		op, index string // the index content before the pick
		worktree  string // f.txt after the command
		staged    string // the index's f.txt after the command
	}{
		{"stage", base, edited, second},
		{"unstage", edited, edited, first},
		{"discard", base, first, base},
	}
	for _, tt := range tests {
		t.Run(tt.op, func(t *testing.T) {
			writeF(t, tt.index)
			git(t, "add", "f.txt")
			writeF(t, edited)
			if err := run(t, pickSecond(t, tt.op)); err != nil {
				t.Fatalf("command failed: %v", err)
			}
			if got, _ := os.ReadFile("f.txt"); string(got) != tt.worktree {
				t.Errorf("f.txt = %q, want %q", got, tt.worktree)
			}
			if got := git(t, "show", ":f.txt"); got != tt.staged {
				t.Errorf("index f.txt = %q, want %q", got, tt.staged)
			}
		})
	}

	t.Run("refuses a changed file", func(t *testing.T) {
		writeF(t, base)
		git(t, "add", "f.txt")
		writeF(t, edited)
		cmd := pickSecond(t, "discard")
		changed := "ONE\n2\n3\n4\nFIVE\n6\n7\n8\nNINE\n" // hunk 2 is now line 5
		writeF(t, changed)
		err := run(t, cmd)
		if got, _ := os.ReadFile("f.txt"); string(got) != changed {
			t.Errorf("f.txt = %q, want it untouched", got)
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			t.Errorf("command succeeded (%v), want it to fail", err)
		}
	})

	t.Run("a glob character in a name is literal", func(t *testing.T) {
		// f[1].txt is also a glob that matches f1.txt: a drill into it must
		// list its own hunk alone.
		for _, name := range []string{"f[1].txt", "f1.txt"} {
			if err := os.WriteFile(name, []byte("a\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			git(t, "add", name)
			if err := os.WriteFile(name, []byte("b\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		p := picker{dir: t.TempDir(), getenv: func(string) string { return "" }, git: runGit}
		if _, err := p.key(pickOps["stage"], "enter", "", "f[1].txt", nil); err != nil {
			t.Fatal(err)
		}
		if hunks, err := readList(p.path(".hunks")); err != nil || len(hunks) != 1 {
			t.Errorf("drilling into f[1].txt lists %q (%v), want its one hunk", hunks, err)
		}
	})
}
