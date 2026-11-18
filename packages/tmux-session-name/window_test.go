package main

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMeaningful(t *testing.T) {
	panes := []pane{
		{program: "nvim", folder: "dotfiles", branch: "feat/zsh-prompt"},
		{program: ".claude-wrapped", folder: "dotfiles", branch: "feat/zsh-prompt", title: "Prompt git status"},
	}
	for _, tc := range []struct{ name, answer, want string }{
		{"as it is", "git-status", "git-status"},
		{"a program taken out", "nvim-prompt", "prompt"},
		{"claude, as tmux names it on macOS", "claude-git-status", "git-status"},
		{"a shell the branch is about stays", "zsh-prompt", "zsh-prompt"},
		{"a shell and a default branch: nothing left", "bash-main", ""},
		{"sanitized", "Prompt Git Status\n", "prompt-git-status"},
		{"3 words once the program is out", "nvim git status bar", "git-status-bar"},
		{"no word", "!!!", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := meaningful(tc.answer, panes); got != tc.want {
				t.Errorf("meaningful(%q) = %q, want %q", tc.answer, got, tc.want)
			}
		})
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

func TestFolderLabel(t *testing.T) {
	for _, tc := range []struct {
		name   string
		panes  []pane
		want   string
		wantOK bool
	}{
		{"one folder", []pane{{program: "nvim", folder: "terminal"}, {program: "zsh", folder: "terminal"}}, "terminal", true},
		{"home", []pane{{program: "htop", folder: "~"}}, "home", true},
		{"two words, as they are", []pane{{program: "zsh", folder: "claude-sandbox"}}, "claude-sandbox", true},
		{"three words", []pane{{program: "zsh", folder: "My.Dot_Files"}}, "my-dot-files", true},
		{"one long word, cut", []pane{{program: "zsh", folder: "Supercalifragilisticexpialidocious"}}, "supercalifragilistic", true},
		{"no word: the program shows", []pane{{program: "htop", folder: "/"}}, "", true},
		{"four words: for the model", []pane{{program: "zsh", folder: "my-new-web-app"}}, "", false},
		{"too long: for the model", []pane{{program: "zsh", folder: "terminal-configuration"}}, "", false},
		{"two folders: for the model", []pane{{program: "zsh", folder: "terminal"}, {program: "zsh", folder: "neovim"}}, "", false},
		{"no panes", nil, "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := folderLabel(tc.panes)
			if got != tc.want || ok != tc.wantOK {
				t.Errorf("folderLabel = %q, %v, want %q, %v", got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

func TestSaysNothing(t *testing.T) {
	titled := []pane{
		{program: "claude", folder: "terminal", branch: "main", title: "Claude window names"},
		{program: "zsh", folder: "terminal", branch: "main"},
	}
	branched := []pane{{program: "claude", folder: "claude-sandbox", branch: "feat/zsh-egress"}}
	for _, tc := range []struct {
		word  string
		panes []pane
		want  bool
	}{
		{"names", titled, false},
		{"terminal", titled, false},
		{"zsh", titled, true},
		{"bash", titled, true},
		{"main", titled, true},     // the branch, but a default one
		{"claude", titled, false},  // the title mentions it
		{"claude", branched, true}, // a program's name, which no title mentions
		{"zsh", branched, false},   // the branch mentions it
		{"sandbox", branched, false},
	} {
		if got := saysNothing(tc.word, tc.panes); got != tc.want {
			t.Errorf("saysNothing(%q, %+v) = %v, want %v", tc.word, tc.panes, got, tc.want)
		}
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
	app := "@5\t5\tzsh\t/home/u/my-new-web-app\tlaptop\n"
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
			name:    "a title: the model's name",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "", 0, "", "")},
			answers: []string{"Window Names\n"},
			asks:    1,
			writes:  []string{"set-option -w -t @2 -- @wlabel window-names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at},
		},
		{
			name:   "a folder of two words: as it is, no model",
			tmux:   fakeTmux{state: pinned, panes: sandbox, windows: windowLine("@3", "", 0, "", "")},
			writes: []string{"set-option -w -t @3 -- @wlabel claude-sandbox ; set-option -w -t @3 -- @wlabel_fp " + fp(sandbox, nil)},
		},
		{
			name:    "a folder of four words: the model picks",
			tmux:    fakeTmux{state: pinned, panes: app, windows: windowLine("@5", "", 0, "", "")},
			answers: []string{"web-app"},
			asks:    1,
			writes:  []string{"set-option -w -t @5 -- @wlabel web-app ; set-option -w -t @5 -- @wlabel_fp " + fp(app, nil) + " ; set-option -w -t @5 -- @wlabel_at " + at},
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
			name:     "the model adds the program: taken out",
			tmux:     fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", "", 0, "", "")},
			branches: feature,
			answers:  []string{"nvim-tmux-names"},
			asks:     1,
			writes:   []string{"set-option -w -t @1 -- @wlabel tmux-names ; set-option -w -t @1 -- @wlabel_fp " + fp(editor, feature) + " ; set-option -w -t @1 -- @wlabel_at " + at},
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
			name:    "the answer has no name",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", old, "", "terminal")},
			answers: []string{"!!!"},
			asks:    1,
			writes:  []string{`set-option -w -t @2 -- @wlabel_at ` + at + ` ; set-option -w -t @2 -- @wlabel_err model: no name in the answer "!!!"`},
			wantErr: true,
		},
		{
			name:    "a later success clears the error",
			tmux:    fakeTmux{state: pinned, panes: claude, windows: windowLine("@2", "stale", old, "model: offline", "terminal")},
			answers: []string{"window-names"},
			asks:    1,
			writes:  []string{"set-option -w -t @2 -- @wlabel window-names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at + " ; set-option -u -w -t @2 @wlabel_err"},
		},
		{
			name: "each window from its own panes",
			tmux: fakeTmux{state: pinned, panes: editor + claude, windows: windowLine("@1", "", 0, "", "") + windowLine("@2", "", 0, "", "")},
			// Only the window with a title asks.
			answers: []string{"window-names"},
			asks:    1,
			writes: []string{
				"set-option -w -t @1 -- @wlabel terminal ; set-option -w -t @1 -- @wlabel_fp " + fp(editor, nil),
				"set-option -w -t @2 -- @wlabel window-names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at,
			},
		},
		{
			name: "a window opened after list-panes",
			tmux: fakeTmux{state: pinned, panes: editor, windows: windowLine("@1", fp(editor, nil), 0, "", "terminal") + windowLine("@9", "", 0, "", "")},
		},
		{
			name:    "the session's label first, then the windows",
			tmux:    fakeTmux{state: stateLine("1", "", "", 0, "", ""), panes: claude, windows: windowLine("@2", "", 0, "", "")},
			answers: []string{"tmux-window-names", "window-names"},
			asks:    2,
			writes: []string{
				"set-option -t $1 -- @label tmux-window-names ; set-option -t $1 -- @label_fp " + fp(claude, nil) + " ; set-option -t $1 -- @label_at " + at,
				"set-option -w -t @2 -- @wlabel window-names ; set-option -w -t @2 -- @wlabel_fp " + fp(claude, nil) + " ; set-option -w -t @2 -- @wlabel_at " + at,
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
			if n := len(queries); n > 0 {
				if q := queries[n-1]; q.system != windowSystemPrompt || q.grammar != labelGrammar || q.cache != "window" {
					t.Errorf("the last query has the %q cache and grammar %q, want the window's", q.cache, q.grammar)
				}
			}
			if !reflect.DeepEqual(f.writes, tc.writes) {
				t.Errorf("writes =\n%q\nwant\n%q", f.writes, tc.writes)
			}
		})
	}
}
