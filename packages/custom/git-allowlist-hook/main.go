// Command git-allowlist-hook is a Claude Code PreToolUse hook that denies any
// shell command which invokes git with a subcommand outside a small read-only
// allowlist. It exits 2 (Claude Code's "block" exit code) on policy violations.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

const denyExitCode = 2

var (
	allowedSubcommands = map[string]struct{}{
		"status": {}, "diff": {}, "log": {}, "show": {}, "branch": {},
		"rev-parse": {}, "config": {}, "remote": {}, "ls-files": {}, "blame": {},
	}
	forbiddenFlags = map[string]struct{}{
		"--no-verify": {}, "--force": {}, "-f": {},
	}
	// Global git flags that consume the next argument as their value.
	globalFlagsWithArg = map[string]struct{}{
		"-C": {}, "-c": {}, "--git-dir": {}, "--work-tree": {},
		"--namespace": {}, "--exec-path": {}, "--config-env": {},
	}
	// Shells whose `-c <script>` argument we recursively parse.
	shellRunners = map[string]struct{}{
		"bash": {}, "sh": {}, "zsh": {}, "dash": {}, "ash": {},
	}
)

type hookInput struct {
	ToolInput struct {
		Command string `json:"command"`
	} `json:"tool_input"`
}

// denyErr signals a policy violation. main exits with denyExitCode when it
// unwraps to one of these.
type denyErr struct{ msg string }

func (e *denyErr) Error() string { return e.msg }

func deny(format string, a ...any) error {
	return &denyErr{msg: "git-allowlist: " + fmt.Sprintf(format, a...)}
}

func main() {
	err := run(os.Stdin)
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, err)
	var d *denyErr
	if errors.As(err, &d) {
		os.Exit(denyExitCode)
	}
	os.Exit(1)
}

func run(r io.Reader) error {
	in, err := parseInput(r)
	if err != nil {
		return fmt.Errorf("git-allowlist: parse hook input: %w", err)
	}
	return checkCommand(in.ToolInput.Command)
}

func parseInput(r io.Reader) (hookInput, error) {
	var in hookInput
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return hookInput{}, err
	}
	return in, nil
}

func checkCommand(cmd string) error {
	if strings.TrimSpace(cmd) == "" {
		return nil
	}
	file, err := syntax.NewParser().Parse(strings.NewReader(cmd), "")
	if err != nil {
		return deny("failed to parse command: %v", err)
	}
	return walkAndCheck(file)
}

func walkAndCheck(node syntax.Node) error {
	var policyErr error
	syntax.Walk(node, func(n syntax.Node) bool {
		if policyErr != nil {
			return false
		}
		call, ok := n.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		first, ok := wordLiteral(call.Args[0])
		if !ok {
			return true
		}
		switch {
		case isGit(first):
			policyErr = checkGitCall(call.Args[1:])
		case isShellRunner(first):
			if inner, ok := extractShellScript(call.Args[1:]); ok {
				policyErr = checkCommand(inner)
			}
		}
		return true
	})
	return policyErr
}

func checkGitCall(args []*syntax.Word) error {
	i := 0
	for i < len(args) {
		tok, ok := wordLiteral(args[i])
		if !ok || !strings.HasPrefix(tok, "-") {
			break
		}
		if strings.Contains(tok, "=") {
			i++
			continue
		}
		if _, takesArg := globalFlagsWithArg[tok]; takesArg {
			i += 2
			continue
		}
		i++
	}
	if i >= len(args) {
		return deny("git invoked without a subcommand")
	}
	sub, ok := wordLiteral(args[i])
	if !ok {
		return deny("cannot statically resolve git subcommand")
	}
	if _, allowed := allowedSubcommands[sub]; !allowed {
		return deny("%q is not in the allowlist", "git "+sub)
	}
	for _, w := range args[i+1:] {
		tok, ok := wordLiteral(w)
		if !ok {
			continue
		}
		if tok == "--" {
			break
		}
		flag := tok
		if eq := strings.IndexByte(flag, '='); eq >= 0 {
			flag = flag[:eq]
		}
		if _, bad := forbiddenFlags[flag]; bad {
			return deny("forbidden flag %s", flag)
		}
	}
	return nil
}

// wordLiteral returns the static string value of a Word when every part is a
// literal (raw, single-quoted, or double-quoted with no expansions). It returns
// false if the word contains any parameter, command, or arithmetic expansion --
// in which case the value cannot be known without executing the shell.
func wordLiteral(w *syntax.Word) (string, bool) {
	var b strings.Builder
	for _, part := range w.Parts {
		switch p := part.(type) {
		case *syntax.Lit:
			b.WriteString(p.Value)
		case *syntax.SglQuoted:
			b.WriteString(p.Value)
		case *syntax.DblQuoted:
			for _, inner := range p.Parts {
				lit, ok := inner.(*syntax.Lit)
				if !ok {
					return "", false
				}
				b.WriteString(lit.Value)
			}
		default:
			return "", false
		}
	}
	return b.String(), true
}

func isGit(name string) bool {
	return name == "git" || strings.HasSuffix(name, "/git")
}

func isShellRunner(name string) bool {
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	_, ok := shellRunners[name]
	return ok
}

// extractShellScript returns the script string passed via `-c` to a shell.
func extractShellScript(args []*syntax.Word) (string, bool) {
	for i := 0; i < len(args)-1; i++ {
		tok, ok := wordLiteral(args[i])
		if !ok {
			continue
		}
		if tok == "-c" {
			return wordLiteral(args[i+1])
		}
	}
	return "", false
}
