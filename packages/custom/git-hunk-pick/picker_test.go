package main

import (
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fooDiff gives foo.txt two hunks; every other path has no diff.
var fooDiff = fooHeader + fooHunk1 + fooHunk2

// TestPickerKeyAndLoad presses one key, then runs load as fzf would once the
// reload lands. The files list is bar.txt, foo.txt.
func TestPickerKeyAndLoad(t *testing.T) {
	tests := []struct {
		name    string
		drilled string            // the hunks list for this file is up
		state   pickerState       // state.json before the key
		query   string            // the files query saved at the drill
		env     map[string]string // FZF_SELECT_COUNT, FZF_QUERY, FZF_INPUT_STATE
		key     string
		item    string
		marked  []string // the selection file, {+f}
		sel     []int    // {+n}
		want    string   // key's actions; <dir> is the state directory
		load    string   // load's actions
		spec    string   // foo.txt's spec afterwards
		drill   string   // .drill afterwards
		whole   string   // .whole when finalized
	}{
		{name: "left edits the query", key: "left", want: "backward-char"},
		{name: "esc aborts from search mode", key: "esc", want: "abort"},
		{name: "esc leaves nav mode", key: "esc", env: map[string]string{"FZF_INPUT_STATE": "disabled"}, want: "trigger(alt-i)"},
		{name: "right on a file without hunks", key: "right", item: "new.txt"},
		{
			name: "enter on a file without hunks finalizes", key: "enter", item: "new.txt",
			env: map[string]string{"FZF_SELECT_COUNT": "1"}, marked: []string{"bar.txt"},
			want: "accept", whole: "bar.txt\n",
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
			state: pickerState{Specs: map[string]string{"foo.txt": "2"}},
			want:  "reload-sync(cat '<dir>/.hunks')", load: "change-header(H)+pos(2)+select+first", spec: "2", drill: "foo.txt",
		},
		{name: "right in the hunks list edits the query", drilled: "foo.txt", key: "right", want: "forward-char", drill: "foo.txt"},
		{
			name: "back records a subset and restores marks and cursor", drilled: "foo.txt", key: "left",
			state: pickerState{Marks: []string{"bar.txt"}},
			env:   map[string]string{"FZF_SELECT_COUNT": "1"}, sel: []int{1},
			want: "reload-sync(cat '<dir>/.files')", load: "change-header(F)+pos(1)+select+pos(2)+select+pos(2)", spec: "2",
		},
		{
			name: "back with nothing marked drops the file and restores the query", drilled: "foo.txt", key: "esc",
			state: pickerState{Marks: []string{"bar.txt", "foo.txt"}, Specs: map[string]string{"foo.txt": "1"}},
			query: "fo", env: map[string]string{"FZF_QUERY": "x"},
			want: "reload-sync(cat '<dir>/.files')",
			load: "change-header(F)+change-query()+wait+pos(1)+select+pos(2)+" +
				"track-current+transform-query(cat '<dir>/.query')+wait+untrack-current",
		},
		{
			name: "enter in the hunks list finalizes as shown", drilled: "foo.txt", key: "enter",
			state: pickerState{Marks: []string{"bar.txt"}},
			env:   map[string]string{"FZF_SELECT_COUNT": "2"}, sel: []int{1, 0},
			want: "accept", spec: "ALL", drill: "foo.txt", whole: "bar.txt\nfoo.txt\n",
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
			write(".files", "bar.txt\nfoo.txt\n")
			write("sel", strings.Join(tt.marked, "\n"))
			if tt.drilled != "" {
				files, _ := parseDiff(strings.NewReader(fooDiff))
				write(".drill", tt.drilled+"\n")
				write(".hunks", strings.Join(labels(files), "\n")+"\n")
			}
			write(".query", tt.query)
			env := map[string]string{"GFS_HEADER_FILES": "F", "GFS_HEADER_HUNKS": "H"}
			maps.Copy(env, tt.env)
			p := picker{
				dir:    dir,
				getenv: func(k string) string { return env[k] },
				diff: func(_ bool, path string) (string, error) {
					if path == "foo.txt" {
						return fooDiff, nil
					}
					return "", nil
				},
			}
			if err := p.saveState(tt.state); err != nil {
				t.Fatal(err)
			}

			got, err := p.key(false, tt.key, filepath.Join(dir, "sel"), tt.item, tt.sel)
			if err != nil {
				t.Fatalf("key: %v", err)
			}
			loaded, err := p.load()
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			st, _ := p.loadState()
			drill, _ := os.ReadFile(filepath.Join(dir, ".drill"))
			whole, err := os.ReadFile(filepath.Join(dir, ".whole"))
			if errors.Is(err, fs.ErrNotExist) {
				whole = nil
			}
			in := func(s string) string { return strings.ReplaceAll(s, "<dir>", dir) }
			if got != in(tt.want) {
				t.Errorf("key = %q, want %q", got, in(tt.want))
			}
			if loaded != in(tt.load) {
				t.Errorf("load = %q, want %q", loaded, in(tt.load))
			}
			if st.Specs["foo.txt"] != tt.spec {
				t.Errorf("spec = %q, want %q", st.Specs["foo.txt"], tt.spec)
			}
			if d := strings.TrimSuffix(string(drill), "\n"); d != tt.drill {
				t.Errorf(".drill = %q, want %q", d, tt.drill)
			}
			if string(whole) != tt.whole {
				t.Errorf(".whole = %q, want %q", whole, tt.whole)
			}
		})
	}
}

func TestPickerGetHint(t *testing.T) {
	dir := t.TempDir()
	if err := (picker{dir: dir}).saveState(pickerState{Specs: map[string]string{"a.go": "ALL", "b.go": "1 3"}}); err != nil {
		t.Fatal(err)
	}
	tests := []struct{ cmd, path, want string }{
		{"get", "a.go", "ALL\n"},
		{"get", "c.go", ""},
		{"hint", "b.go", "◐ hunks: 1 3\n"},
		{"hint", "a.go", ""}, // whole: fzf's own marker shows it
	}
	for _, tt := range tests {
		var b strings.Builder
		if err := runPicker(tt.cmd, []string{dir, tt.path}, &b); err != nil {
			t.Fatalf("%s %s: %v", tt.cmd, tt.path, err)
		}
		if b.String() != tt.want {
			t.Errorf("%s %s = %q, want %q", tt.cmd, tt.path, b.String(), tt.want)
		}
	}
}
