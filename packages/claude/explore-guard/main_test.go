package main

import (
	"slices"
	"strings"
	"testing"
)

func TestCheck(t *testing.T) {
	tests := []struct {
		name    string
		command string
		pass    bool
	}{
		// git subcommands that read.
		{"git log", "git log --oneline -5", true},
		{"git -C dir", "git -C /home/u/repo status --short", true},
		{"git no-pager", "git --no-pager show 'HEAD:flake.nix'", true},
		{"git grep quoted alternation", "git grep -n 'foo|bar' -- '*.go'", true},
		{"git diff cached", "git diff --cached --stat", true},
		{"git blame range", "git blame -L 10,20 main.go", true},
		{"git log quoted format", "git log --format='%h %s' -n 3", true},
		{"git log quoted revision", "git log --oneline 'HEAD~3..HEAD'", true},
		{"git output indicator isn't output", "git diff --output-indicator-new=+", true},
		{"git grep or isn't a pager", "git grep -e a --or -e b", true},
		{"git branch", "git branch", true},
		{"git branch all", "git branch -a", true},
		{"git branch very verbose", "git branch -vv", true},
		{"git branch list pattern", "git branch --list 'feat*'", true},
		{"git branch list short", "git branch -l 'feat*'", true},
		{"git branch contains", "git branch --contains main", true},
		{"git branch merged", "git branch --merged=main", true},
		{"git branch show current", "git branch --show-current", true},
		{"git branch sort", "git branch --sort=-committerdate", true},
		{"git branch format", "git branch --format='%(refname:short)'", true},

		// git subcommands and options that write.
		{"git stash", "git stash", false},
		{"git add", "git add .", false},
		{"git rebase", "git rebase main", false},
		{"git checkout", "git checkout -- .", false},
		{"git log output", "git log --output=/tmp/x", false},
		{"git diff output abbreviated", "git diff --out=/tmp/x", false},
		{"git show output then file", "git show --output /tmp/x", false},
		{"git grep pager", "git grep -O foo", false},
		{"git grep pager clustered", "git grep -nO foo", false},
		{"git grep pager long abbreviated", "git grep --open foo", false},
		{"git config injection", "git -c core.pager=sh log", false},
		{"git exec path", "git --exec-path=/tmp log", false},
		{"git branch create", "git branch topic", false},
		{"git branch create with start", "git branch topic main", false},
		{"git branch delete", "git branch -D topic", false},
		{"git branch delete clustered", "git branch -vd topic", false},
		{"git branch delete long abbreviated", "git branch --del topic", false},
		{"git branch move", "git branch -m old new", false},
		{"git branch upstream", "git branch --set-upstream-to=origin/main", false},
		{"git branch verbose with a name", "git branch -v topic", false},
		{"git branch name after dashes", "git branch -- topic", false},
		{"git sort value not after =", "git branch --sort committerdate", false},
		{"git without subcommand", "git", false},
		{"git -C without directory", "git -C", false},
		{"git alias", "git lg", false},

		// coreutils.
		{"ls", "ls -la src", true},
		{"cat", "cat flake.nix", true},
		{"head quoted file", "head -n 20 'a file.txt'", true},
		{"tail", "tail -n 5 log.txt", true},
		{"wc", "wc -l main.go", true},

		// grep.
		{"grep recursive", "grep -rn 'TODO|FIXME' src", true},
		{"grep double-quoted", `grep -F "two words" README.md`, true},
		{"grep perl", "grep --perl-regexp 'a+b' x", true},
		{"grep pretty isn't pre", "grep --pretty foo x", true},
		{"grep count isn't config", "grep --count foo x", true},
		{"grep file isn't filter", "grep --file=patterns x", true},
		{"grep filter", "grep --filter='pdf:pdftotext % -' -r x .", false},
		{"grep filter extension", "grep --filter-magic-label=x foo", false},
		{"grep filter abbreviated", "grep --filt=x foo", false},
		{"grep pager", "grep --pager=less foo x", false},
		{"grep view", "grep --view foo x", false},
		{"grep query", "grep -Q foo", false},
		{"grep query clustered", "grep -rnQ foo", false},
		{"grep config", "grep --config=evil foo", false},
		{"grep config shorthand", "grep ---evil foo", false},
		{"grep save config", "grep --save-config foo", false},
		{"grep pre", "grep --pre=sh foo", false},

		// find.
		{"find quoted name", "find . -name '*.go' -type f", true},
		{"find print", "find src -maxdepth 2 -print", true},
		{"find delete", "find . -name x -delete", false},
		{"find rm", "find . -rm", false},
		{"find exec", "find . -exec cat '{}' ';'", false},
		{"find execdir", "find . -execdir cat '{}' +", false},
		{"find ok", "find . -ok cat '{}' ';'", false},
		{"find fprint", "find . -fprint out", false},
		{"find fls", "find . -fls out", false},
		{"find quoted action", "find . '-delete'", false},

		// The grammar.
		{"pipe", "git log | head", false},
		{"quoted pipe", "grep 'a|b' x", true},
		{"and list", "ls && rm x", false},
		{"semicolon", "ls; rm x", false},
		{"background", "ls &", false},
		{"redirect out", "cat a > b", false},
		{"redirect in", "cat < a", false},
		{"command substitution", "cat $(echo x)", false},
		{"backticks", "cat `echo x`", false},
		{"variable", "cat $HOME/x", false},
		{"variable in double quotes", `cat "$HOME/x"`, false},
		{"backslash in double quotes", `grep "a\b" x`, false},
		{"backslash unquoted", `grep a\|b x`, false},
		{"unquoted glob", "ls /nix/store/*/bin/foo", false},
		{"unquoted question mark", "ls file?.txt", false},
		{"unquoted bracket", "ls file[12]", false},
		{"brace expansion", "cat {a,b}", false},
		{"tilde", "cat ~/x", false},
		{"unquoted revision", "git show HEAD~1", false},
		{"caret", "git show HEAD^", false},
		{"zsh equals expansion", "cat =ls", false},
		{"equals mid-word", "git log --format=%h", true},
		{"quoted equals first", "grep '=x' y", true},
		{"newline", "ls\nrm x", false},
		{"newline in quotes", "grep 'a\nb' x", false},
		{"comment", "ls # x", false},
		{"subshell", "(ls)", false},
		{"unterminated quote", "grep 'foo x", false},
		{"env assignment", "GIT_PAGER=sh git log", false},
		{"other program", "rm -rf x", false},
		{"sed", "sed -i s/a/b/ x", false},
		{"path to git", "/usr/bin/git log", false},
		{"empty", "", false},
		{"blank", "   ", false},
		{"surrounding blanks", "  git status  ", true},
		{"tab", "git\tstatus", true},
		{"empty quoted word", "grep '' x", true},
		{"unquoted non-ASCII", "cat café", false},
		{"quoted non-ASCII", "cat 'café'", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := check(tt.command)
			if (err == nil) != tt.pass {
				t.Errorf("check(%q) = %v, want pass %v", tt.command, err, tt.pass)
			}
		})
	}
}

func TestSplit(t *testing.T) {
	tests := []struct {
		command string
		want    []string
	}{
		{"git log --format='%h %s'", []string{"git", "log", "--format=%h %s"}},
		{`grep -F "two words" x`, []string{"grep", "-F", "two words", "x"}},
		{"a'b'\"c\"d", []string{"abcd"}},
		{"grep '' x", []string{"grep", "", "x"}},
		{" \tls\t a ", []string{"ls", "a"}},
		{"", nil},
	}
	for _, tt := range tests {
		got, err := split(tt.command)
		if err != nil || !slices.Equal(got, tt.want) {
			t.Errorf("split(%q) = %q, %v, want %q", tt.command, got, err, tt.want)
		}
	}
}

func TestRun(t *testing.T) {
	tests := []struct {
		name  string
		input string
		pass  bool
	}{
		{"command that reads", `{"tool_name":"Bash","tool_input":{"command":"git status"}}`, true},
		{"command that writes", `{"tool_name":"Bash","tool_input":{"command":"git stash"}}`, false},
		{"other tool", `{"tool_name":"Read","tool_input":{"file_path":"x"}}`, false},
		{"no command", `{"tool_name":"Bash","tool_input":{}}`, false},
		{"command not a string", `{"tool_name":"Bash","tool_input":{"command":1}}`, false},
		{"malformed", `{not json`, false},
		{"empty", ``, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := run(strings.NewReader(tt.input))
			if (err == nil) != tt.pass {
				t.Errorf("run(%s) = %v, want pass %v", tt.input, err, tt.pass)
			}
		})
	}
}
