// Command claude-explore-guard keeps the Explore agent's shell to commands
// that only read. Claude Code's built-in Explore runs any shell command the
// session's permission mode lets through, so in auto or bypass mode it can
// write. sources/.claude/agents/explore.md replaces it with an agent that has
// only Read, LSP and Bash, and runs this as its PreToolUse hook on Bash.
//
// # Protocol
//
// The agent's hook runs it with no arguments and the event's JSON on stdin. A
// command that passes exits 0 with no output, which leaves the call to the
// permission flow and the session's other hooks: git-allowlist-hook still vets
// a git command, and git-shim runs it. Anything else exits 2 with the reason
// on stderr, which blocks the call and tells Claude why: a command that fails
// the check, an event for another tool, input it can't read. The hook entry
// sets onFailure: block, so a guard that can't run blocks too.
//
// # What passes
//
// One simple command, in a subset of the shell's grammar where the words the
// check reads are the words the shell runs, in bash and zsh alike. A word is
// made of plain characters (letters, digits and _./:@%+,=-, but no = first,
// which zsh expands), single-quoted text, and double-quoted text without $, `,
// \ or !. Spaces and tabs separate words. So no pipe, list, redirection,
// substitution, expansion or unquoted wildcard (zsh's extended glob makes ~,
// ^ and # wildcards too), and no control character, even quoted. The program
// is one of:
//
//   - git, with only -C <dir>, --no-pager, -P or --no-optional-locks before
//     a subcommand that reads (readGit). Never --output, which writes a file,
//     under any abbreviation git accepts; grep never opens the matches in a
//     pager; branch only lists.
//   - ls, cat, head, tail, wc: coreutils, none of whose options writes or
//     runs anything.
//   - grep, which is ugrep in Claude's shell: none of the options that run a
//     command, read a config that can, write one or start an interactive
//     search.
//   - find, which is bfs in Claude's shell: none of the actions that run a
//     command or delete or write a file.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

func main() {
	if err := run(os.Stdin); err != nil {
		fmt.Fprintf(os.Stderr, "claude-explore-guard: blocked: %v\n", err)
		os.Exit(2)
	}
}

// event is the part of the PreToolUse event the guard reads.
type event struct {
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		Command *string `json:"command"`
	} `json:"tool_input"`
}

// run reads the hook event from r and returns why its command is blocked, or
// nil when it passes.
func run(r io.Reader) error {
	var ev event
	if err := json.NewDecoder(r).Decode(&ev); err != nil {
		return fmt.Errorf("can't read the hook event: %w", err)
	}
	if ev.ToolName != "Bash" {
		return fmt.Errorf("it only vets Bash commands, not %q calls", ev.ToolName)
	}
	if ev.ToolInput.Command == nil {
		return errors.New("the Bash call has no command")
	}
	return check(*ev.ToolInput.Command)
}

// check returns why command is blocked, or nil when it passes.
func check(command string) error {
	words, err := split(command)
	if err != nil {
		return err
	}
	if len(words) == 0 {
		return errors.New("the command is empty")
	}
	switch prog, args := words[0], words[1:]; prog {
	case "git":
		return checkGit(args)
	case "ls", "cat", "head", "tail", "wc":
		return nil
	case "grep":
		return checkGrep(args)
	case "find":
		return checkFind(args)
	default:
		return fmt.Errorf("%s is not a command this agent runs: git, ls, cat, head, tail, wc, grep and find are", prog)
	}
}

// split returns the words of command, or why command steps outside the
// grammar the package comment describes.
func split(command string) ([]string, error) {
	for _, c := range []byte(command) {
		if c < ' ' && c != '\t' || c == 0x7f {
			return nil, fmt.Errorf("control character %q: one command, on one line", c)
		}
	}
	var words []string
	var word strings.Builder
	inWord := false
	for i := 0; i < len(command); {
		c := command[i]
		switch {
		case c == ' ' || c == '\t':
			if inWord {
				words = append(words, word.String())
				word.Reset()
				inWord = false
			}
			i++
		case c == '\'' || c == '"':
			end := strings.IndexByte(command[i+1:], c)
			if end < 0 {
				return nil, fmt.Errorf("unterminated %c quote", c)
			}
			text := command[i+1 : i+1+end]
			if c == '"' {
				if j := strings.IndexAny(text, "$`\\!"); j >= 0 {
					return nil, fmt.Errorf("%q in double quotes: use single quotes", text[j])
				}
			}
			word.WriteString(text)
			inWord = true
			i += end + 2
		case plain(c):
			if c == '=' && !inWord {
				return nil, errors.New("a word starts with an unquoted =, which zsh expands: quote it")
			}
			word.WriteByte(c)
			inWord = true
			i++
		default:
			return nil, fmt.Errorf("unquoted %q: one command, with no pipe, list, redirection, substitution or expansion; quote a pattern or a revision such as 'HEAD~1'", c)
		}
	}
	if inWord {
		words = append(words, word.String())
	}
	return words, nil
}

// plain reports whether c means itself unquoted, in bash and zsh alike.
func plain(c byte) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' ||
		strings.IndexByte("_./:@%+,=-", c) >= 0
}

// readGit are the git subcommands the agent runs, all of which only read.
// git-allowlist-hook lets more through, some of which write: add, stash,
// rebase.
var readGit = []string{
	"status", "diff", "log", "show", "blame", "grep", "ls-files", "ls-tree",
	"cat-file", "rev-parse", "rev-list", "merge-base", "branch",
}

func checkGit(args []string) error {
	i := 0
	for ; i < len(args) && strings.HasPrefix(args[i], "-"); i++ {
		switch args[i] {
		case "--no-pager", "-P", "--no-optional-locks":
		case "-C":
			if i++; i == len(args) {
				return errors.New("git -C needs a directory")
			}
		default:
			return fmt.Errorf("git %s: before the subcommand, only -C <dir>, --no-pager, -P and --no-optional-locks", args[i])
		}
	}
	if i == len(args) {
		return errors.New("git needs a subcommand")
	}
	sub, rest := args[i], args[i+1:]
	if !slices.Contains(readGit, sub) {
		return fmt.Errorf("git %s: the subcommands this agent runs are %s", sub, strings.Join(readGit, ", "))
	}
	for _, a := range rest {
		if abbreviates(a, "output") {
			return fmt.Errorf("git %s %s writes a file", sub, a)
		}
	}
	switch sub {
	case "grep":
		for _, a := range rest {
			if abbreviates(a, "open-files-in-pager") || shortHas(a, 'O') {
				return fmt.Errorf("git grep %s opens the matches in a pager", a)
			}
		}
	case "branch":
		return checkBranch(rest)
	}
	return nil
}

var (
	// branchFlags only shape how git branch lists.
	branchFlags = []string{
		"--all", "--remotes", "--verbose", "--list", "--show-current",
		"--ignore-case", "--quiet", "--omit-empty", "--color", "--no-color",
		"--column", "--no-column", "--abbrev", "--no-abbrev",
	}
	// branchValued shape the listing too, with a value after =.
	branchValued = []string{"--color", "--column", "--abbrev", "--sort", "--format"}
	// branchFilters pick the branches to list by a commit, which makes git
	// branch list: what follows is a commit or a pattern, never a branch to
	// create.
	branchFilters = []string{"--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
)

// checkBranch lets git branch only list: every option shapes or filters the
// listing, and a name, which would create a branch, comes only with --list or
// a filter, which make it a pattern.
func checkBranch(args []string) error {
	list, named := false, false
	for i, a := range args {
		if a == "--" {
			named = named || i+1 < len(args)
			break
		}
		name, _, valued := strings.Cut(a, "=")
		switch {
		case !strings.HasPrefix(a, "-") || a == "-":
			named = true
		case a == "--list" || slices.Contains(branchFilters, name):
			list = true
		case !valued && slices.Contains(branchFlags, a), valued && slices.Contains(branchValued, name):
		case strings.HasPrefix(a, "--"):
			return fmt.Errorf("git branch %s does more than list branches (give an option's value after =)", a)
		default:
			for _, c := range a[1:] {
				if !strings.ContainsRune("arvliq", c) {
					return fmt.Errorf("git branch -%c does more than list branches", c)
				}
				list = list || c == 'l'
			}
		}
	}
	if named && !list {
		return errors.New("git branch with a name creates a branch: add --list to match names")
	}
	return nil
}

// grepRuns are the long options of Claude's grep, ugrep, that run a command,
// read a config that can, write one or start an interactive search, and
// ripgrep's --pre. Each also covers its abbreviations and the options that
// extend its name, such as --filter-magic-label.
var grepRuns = []string{"filter", "pager", "view", "query", "config", "save-config", "pre"}

func checkGrep(args []string) error {
	for _, a := range args {
		if strings.HasPrefix(a, "---") {
			return fmt.Errorf("grep %s reads a config, which can run commands", a)
		}
		if shortHas(a, 'Q') {
			return fmt.Errorf("grep %s starts an interactive search", a)
		}
		name, ok := longName(a)
		if !ok {
			continue
		}
		for _, opt := range grepRuns {
			if strings.HasPrefix(opt, name) || strings.HasPrefix(name, opt+"-") {
				return fmt.Errorf("grep %s runs a command, reads a config or writes one", a)
			}
		}
	}
	return nil
}

// findWrites are the actions of Claude's find, bfs, that run a command or
// delete or write a file; -rm is bfs's name for -delete.
var findWrites = []string{
	"-exec", "-execdir", "-ok", "-okdir", "-delete", "-rm",
	"-fprint", "-fprint0", "-fprintf", "-fls",
}

func checkFind(args []string) error {
	for _, a := range args {
		if slices.Contains(findWrites, a) {
			return fmt.Errorf("find %s runs a command or deletes or writes a file", a)
		}
	}
	return nil
}

// longName returns the name in a long option, --name or --name=value, and
// whether arg is one.
func longName(arg string) (string, bool) {
	if !strings.HasPrefix(arg, "--") {
		return "", false
	}
	name, _, _ := strings.Cut(arg[2:], "=")
	return name, name != ""
}

// abbreviates reports whether arg is the long option --opt, with or without a
// value, or an abbreviation of it, which git and getopt take when it is
// unambiguous.
func abbreviates(arg, opt string) bool {
	name, ok := longName(arg)
	return ok && strings.HasPrefix(opt, name)
}

// shortHas reports whether arg is a cluster of short options, such as -nO,
// that holds c.
func shortHas(arg string, c byte) bool {
	return len(arg) > 1 && arg[0] == '-' && arg[1] != '-' && strings.IndexByte(arg[1:], c) >= 0
}
