package main

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestWord(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"naming", "naming"},
		{"Kernel\n", "kernel"},
		{"lsp-fix", "lsp"},
		{"#[fg=red]", "fg"},
		{"infrastructure", "infrastructu"},
		{"first\nsecond", "first"},
		{"", ""},
		{"!!!", ""},
	} {
		if got := word(tc.in); got != tc.want {
			t.Errorf("word(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestPlain(t *testing.T) {
	for _, tc := range []struct {
		name  string
		panes []pane
		want  bool
	}{
		{"programs in their folders", []pane{{program: "nvim", folder: "terminal", branch: "main"}, {program: "zsh", folder: "~"}}, true},
		{"master", []pane{{program: "node", folder: "front", branch: "master"}}, true},
		{"a title", []pane{{program: "nvim", folder: "terminal"}, {program: "claude", folder: "terminal", title: "Fix the bar"}}, false},
		{"a feature branch", []pane{{program: "nvim", folder: "front", branch: "feat/login"}}, false},
	} {
		if got := plain(tc.panes); got != tc.want {
			t.Errorf("%s: plain = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestFolderWord(t *testing.T) {
	for _, tc := range []struct {
		name   string
		panes  []pane
		want   string
		wantOK bool
	}{
		{"one folder", []pane{{program: "nvim", folder: "terminal"}, {program: "zsh", folder: "terminal"}}, "terminal", true},
		{"home", []pane{{program: "htop", folder: "~"}}, "home", true},
		{"cut to 12", []pane{{program: "zsh", folder: "Infrastructure"}}, "infrastructu", true},
		{"no word: the program shows", []pane{{program: "htop", folder: "/"}}, "", true},
		{"two words: for the model", []pane{{program: "zsh", folder: "claude-sandbox"}}, "", false},
		{"two folders: for the model", []pane{{program: "zsh", folder: "terminal"}, {program: "zsh", folder: "neovim"}}, "", false},
		{"no panes", nil, "", false},
	} {
		got, ok := folderWord(tc.panes)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("%s: folderWord = %q, %v, want %q, %v", tc.name, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestSaysNothing(t *testing.T) {
	panes := []pane{
		{program: "claude", folder: "terminal", branch: "main", title: "Claude window names"},
		{program: "zsh", folder: "terminal", branch: "main"},
	}
	for _, tc := range []struct {
		word string
		want bool
	}{
		{"names", false},
		{"terminal", false},
		{"zsh", true},
		{"bash", true},
		{"main", true},
		{"claude", false}, // the title mentions it
	} {
		if got := saysNothing(tc.word, panes); got != tc.want {
			t.Errorf("saysNothing(%q) = %v, want %v", tc.word, got, tc.want)
		}
	}
	if !saysNothing("claude", []pane{{program: "claude", folder: "claude-sandbox", branch: "egress"}}) {
		t.Error("a program's name, which no title mentions, says something")
	}
}

func TestWindowLines(t *testing.T) {
	got := windowLines([]pane{
		{window: "2", program: "claude", folder: "terminal", branch: "main", title: "Tmux window names"},
		{window: "2", program: "zsh", folder: "terminal", branch: "main"},
		{window: "2", program: "zsh", folder: "terminal", branch: "main"},
	})
	if want := "claude terminal main \"Tmux window names\"\nzsh terminal main\n"; got != want {
		t.Errorf("windowLines =\n%s\nwant\n%s", got, want)
	}
}

// windowLine is a line of list-windows output in windowFormat.
func windowLine(id, fp string, at int64, errText, label string) string {
	return strings.Join([]string{id, fp, fmt.Sprint(at), errText, label}, "\t") + "\n"
}

func TestRunWindows(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	at := fmt.Sprint(now.Unix())
	recent := now.Add(-10 * time.Second).Unix()
	old := now.Add(-10 * time.Minute).Unix()
	// The session's label is a pin it already shows, so run only names the
	// windows, except where a case says otherwise.
	pinned := stateLine("1", "mine", "", 0, "", "mine")
	editor := "@1\t1\tnvim\t/home/u/terminal\tlaptop\n"
	claude := "@2\t2\tclaude\t/home/u/terminal\t✳ Tmux window names\n"
	sandbox := "@3\t3\tzsh\t/home/u/claude-sandbox\tlaptop\n"
	root := "@4\t4\thtop\t/\tlaptop\n"
	fp := func(lines string, branches map[string]string) string {
		return fingerprint(parsePanes(lines, "/home/u", "laptop", func(dir string) string { return branches[dir] }))
	}
	feature := map[string]string{"/home/u/terminal": "tmux-names"}
	for _, tc := range []struct {
		name     string
		tmux     fakeTmux
		force    bool
		branches map[string]string
		answers  []string
		failing  bool
		asks     int
		writes   []string
		wantErr  bool
	}{
		{
			name:   "a plain window: its folder, no model",
			tmux:   fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", "", 0, "", "")},
			writes: []string{"set-option -w -t @1 -- @wlabel terminal ; set-option -w -t @1 -- @wlabel_fp " + fp(editor, nil)},
		},
		{
			name: "nothing changed",
			tmux: fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", fp(editor, nil), 0, "", "terminal")},
		},
		{
			name:   "no word in the folder: the window list shows the program",
			tmux:   fakeTmux{state: pinned, panes: root, windows: windowLine("@4", "", 0, "", "")},
			writes: []string{"set-option -w -t @4 -- @wlabel_fp " + fp(root, nil)},
		},
		{
			name:    "a title: the model's word",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "", 0, "", "")},
			answers: []string{"Names\n"},
			asks:    1,
			writes:  []string{"set-option -w -t @2 -- @wlabel names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at},
		},
		{
			name:    "a folder of two words: the model picks one",
			tmux:    fakeTmux{state: pinned, panes: sandbox, windows: windowLine("@3", "", 0, "", "")},
			answers: []string{"sandbox"},
			asks:    1,
			writes:  []string{"set-option -w -t @3 -- @wlabel sandbox ; set-option -w -t @3 -- @wlabel_fp " + fp(sandbox, nil) + " ; set-option -w -t @3 -- @wlabel_at " + at},
		},
		{
			name:     "the model names the program: the folder instead",
			tmux:     fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", "", 0, "", "")},
			branches: feature,
			answers:  []string{"nvim"},
			asks:     1,
			writes:   []string{"set-option -w -t @1 -- @wlabel terminal ; set-option -w -t @1 -- @wlabel_fp " + fp(editor, feature) + " ; set-option -w -t @1 -- @wlabel_at " + at},
		},
		{
			name: "changed within the cooldown",
			tmux: fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", recent, "", "terminal")},
		},
		{
			name:  "forced: the windows keep their cooldown",
			tmux:  fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", recent, "", "terminal")},
			force: true,
		},
		{
			name:    "the model fails: keep the name, note why",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", old, "", "terminal")},
			failing: true,
			asks:    1,
			writes:  []string{"set-option -w -t @2 -- @wlabel_at " + at + " ; set-option -w -t @2 -- @wlabel_err model: offline"},
			wantErr: true,
		},
		{
			name:    "a later success clears the error",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", old, "model: offline", "terminal")},
			answers: []string{"names"},
			asks:    1,
			writes:  []string{"set-option -w -t @2 -- @wlabel names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at + " ; set-option -u -w -t @2 @wlabel_err"},
		},
		{
			name: "each window from its own panes",
			tmux: fakeTmux{state: pinned, panes: editor + claude, windows: windowLine("@1", "", 0, "", "") + windowLine("@2", "", 0, "", "")},
			// Only the window with a title asks.
			answers: []string{"names"},
			asks:    1,
			writes: []string{
				"set-option -w -t @1 -- @wlabel terminal ; set-option -w -t @1 -- @wlabel_fp " + fp(editor, nil),
				"set-option -w -t @2 -- @wlabel names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at,
			},
		},
		{
			name: "a window opened after list-panes",
			tmux: fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", fp(editor, nil), 0, "", "terminal") + windowLine("@9", "", 0, "", "")},
		},
		{
			name:    "the session's label first, then the windows",
			tmux:    fakeTmux{state: stateLine("1", "", "", 0, "", ""), panes: claude, windows: windowLine("@2", "", 0, "", "")},
			answers: []string{"tmux-window-names", "names"},
			asks:    2,
			writes: []string{
				"set-option -t $1 -- @label tmux-window-names ; set-option -t $1 -- @label_fp " + fp(claude, nil) + " ; set-option -t $1 -- @label_at " + at,
				"set-option -w -t @2 -- @wlabel names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at,
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := tc.tmux
			var queries []query
			d := deps{
				tmux: f.run,
				ask: func(q query) (string, error) {
					queries = append(queries, q)
					if tc.failing {
						return "", errors.New("offline")
					}
					if len(queries) > len(tc.answers) {
						return "", errors.New("no answer left")
					}
					return tc.answers[len(queries)-1], nil
				},
				branch: func(dir string) string { return tc.branches[dir] },
				lock: func(string) (func(), bool) {
					return func() {}, true
				},
				now:  now,
				home: "/home/u",
			}
			err := run("$1", tc.force, d)
			if (err != nil) != tc.wantErr {
				t.Errorf("run error = %v, want error %v", err, tc.wantErr)
			}
			if len(queries) != tc.asks {
				t.Errorf("model asked %d times, want %d", len(queries), tc.asks)
			}
			if n := len(queries); n > 0 && queries[n-1].grammar != wordGrammar {
				t.Errorf("the last query's grammar is %q, want the window's %q", queries[n-1].grammar, wordGrammar)
			}
			if !reflect.DeepEqual(f.writes, tc.writes) {
				t.Errorf("writes =\n%q\nwant\n%q", f.writes, tc.writes)
			}
		})
	}
}
