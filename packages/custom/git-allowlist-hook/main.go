// Command git-allowlist-hook is a Claude Code PreToolUse hook that denies any
// shell command which invokes git with a subcommand outside a small read-only
// allowlist. It emits a structured PreToolUse permissionDecision JSON document
// on stdout. Any internal error (malformed input, unparseable shell) maps to a
// deny, so the hook fails closed: a hook that cannot enforce policy must not
// let the tool call through.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

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
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		Command string `json:"command"`
	} `json:"tool_input"`
}

type hookOutput struct {
	HookSpecificOutput hookSpecificOutput `json:"hookSpecificOutput"`
}

type hookSpecificOutput struct {
	HookEventName            string `json:"hookEventName"`
	PermissionDecision       string `json:"permissionDecision"`
	PermissionDecisionReason string `json:"permissionDecisionReason"`
}

func main() {
	out := decide(os.Stdin)
	if out == nil {
		return
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		// stdout write failed; fall back to exit-code blocking so the call is denied.
		fmt.Fprintln(os.Stderr, "git-allowlist:", err)
		os.Exit(2)
	}
}

// decide returns nil to allow the tool call, or a deny payload to block it.
// Errors at any layer (input parse, shell parse, policy) are converted to
// denies so the hook fails closed.
func decide(r io.Reader) *hookOutput {
	in, err := parseInput(r)
	if err != nil {
		return denyOutput(fmt.Sprintf("parse hook input: %v", err))
	}
	if in.ToolName != "" && in.ToolName != "Bash" {
		return nil
	}
	if err := checkCommand(in.ToolInput.Command); err != nil {
		return denyOutput(err.Error())
	}
	return nil
}

func denyOutput(reason string) *hookOutput {
	return &hookOutput{
		HookSpecificOutput: hookSpecificOutput{
			HookEventName:            "PreToolUse",
			PermissionDecision:       "deny",
			PermissionDecisionReason: "git-allowlist: " + reason,
		},
	}
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
		return fmt.Errorf("failed to parse command: %v", err)
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
		return errors.New("git invoked without a subcommand")
	}
	sub, ok := wordLiteral(args[i])
	if !ok {
		return errors.New("cannot statically resolve git subcommand")
	}
	if _, allowed := allowedSubcommands[sub]; !allowed {
		return fmt.Errorf("%q is not in the allowlist", "git "+sub)
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
			return fmt.Errorf("forbidden flag %s", flag)
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

func isGit(name string) bool { return path.Base(name) == "git" }

func isShellRunner(name string) bool {
	_, ok := shellRunners[path.Base(name)]
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
