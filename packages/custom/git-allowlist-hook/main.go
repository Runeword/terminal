// Command git-allowlist-hook is a Claude Code PreToolUse hook that denies any
// Bash-tool command which directly invokes git with a subcommand outside a
// small read-only allowlist. It emits a structured PreToolUse
// permissionDecision JSON document on stdout. Any internal error (malformed
// input, unparseable shell) maps to a deny, so the hook fails closed on
// parsing errors.
//
// # Policy
//
// Subcommand-only and direct: the bash AST is walked, every direct `git` call
// (literal "git" or any path basename "git") has its subcommand checked
// against defaultAllowedSubcommands (or the CLAUDE_GIT_ALLOWLIST_CONFIG TOML
// extension), and that is it. The hook does *not* recurse into `bash -c
// '...'`, `eval '...'`, heredoc bodies, or prefix wrappers like `xargs git X`
// / `env FOO=x git X` / `nice git X` — those forms pass through this hook
// untouched. The PATH-based git shim in packages/custom/git-shim is the layer
// that catches them, at exec time, by virtue of being installed first on PATH.
//
// This hook's unique value over the shim is catching absolute-path git calls
// (`/usr/bin/git push`) that appear as direct bash command words — the shim
// is bypassed by absolute paths because PATH lookup is skipped.
//
// # Runtime allowlist extension
//
// The allowlist can be extended at runtime via a TOML config file whose path
// is supplied through the CLAUDE_GIT_ALLOWLIST_CONFIG environment variable
// (the claude wrapper points it at config/claude/git-allowlist.toml in the
// repo). Schema:
//
//	allow = ["push", "fetch", "tag"]
//
// Entries are merged with the built-in defaults — additions do not require a
// rebuild when running in dev mode (the path resolves to a symlink into the
// working tree). An unset variable or missing file means no extras; a parse
// error is logged to stderr and also treated as no extras.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"

	"github.com/BurntSushi/toml"
	"mvdan.cc/sh/v3/syntax"
)

const envConfigPath = "CLAUDE_GIT_ALLOWLIST_CONFIG"

var (
	defaultAllowedSubcommands = map[string]struct{}{
		"status": {}, "diff": {}, "log": {}, "show": {}, "branch": {},
		"rev-parse": {}, "config": {}, "remote": {}, "ls-files": {}, "blame": {},
	}
	// Global git flags that consume the next argument as their value. We skip
	// past these to find the subcommand; we do not inspect their values.
	globalFlagsWithArg = map[string]struct{}{
		"-C": {}, "-c": {}, "--git-dir": {}, "--work-tree": {},
		"--namespace": {}, "--config-env": {},
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
	// Empty tool_name is treated as Bash defensively: an emitter that omits
	// the field shouldn't be able to slip past the allowlist.
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
		return fmt.Errorf("failed to parse command: %w", err)
	}
	var policyErr error
	syntax.Walk(file, func(n syntax.Node) bool {
		if policyErr != nil {
			return false
		}
		call, ok := n.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}
		first, ok := wordLiteral(call.Args[0])
		if !ok || !isGit(first) {
			return true
		}
		if err := checkGitCall(call.Args[1:]); err != nil {
			policyErr = err
			return false
		}
		return true
	})
	return policyErr
}

// checkGitCall finds the subcommand past any leading global flags and verifies
// it against the allowlist. No flag or config-value inspection — once the
// subcommand is allowed, the rest of argv is git's problem.
func checkGitCall(args []*syntax.Word) error {
	i := 0
	for i < len(args) {
		tok, ok := wordLiteral(args[i])
		if !ok || !strings.HasPrefix(tok, "-") {
			break
		}
		flag, _, hasValue := splitFlag(tok)
		if _, takesArg := globalFlagsWithArg[flag]; takesArg && !hasValue {
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
	if !isAllowedSubcommand(sub) {
		return fmt.Errorf("%q is not in the allowlist", "git "+sub)
	}
	return nil
}

// splitFlag splits a flag token of the form `--name=value` (or `-c=value`)
// into its name, value, and whether the `=` was present.
func splitFlag(tok string) (name, value string, hasValue bool) {
	if eq := strings.IndexByte(tok, '='); eq >= 0 {
		return tok[:eq], tok[eq+1:], true
	}
	return tok, "", false
}

// wordLiteral returns the static string value of a Word when every part is a
// literal (raw, single-quoted, or double-quoted with no expansions). It
// returns false if the word contains any parameter, command, or arithmetic
// expansion — in which case the value cannot be known without executing the
// shell.
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

func isAllowedSubcommand(sub string) bool {
	if _, ok := defaultAllowedSubcommands[sub]; ok {
		return true
	}
	for _, name := range loadConfigExtras() {
		if name == sub {
			return true
		}
	}
	return false
}

type allowlistConfig struct {
	Allow []string `toml:"allow"`
}

// loadConfigExtras returns the user-supplied subcommand additions, or nil if
// the env var is unset or the file is absent or unparseable. Parse errors are
// logged to stderr so the user notices a broken config, but the hook still
// falls back to defaults rather than denying every git invocation.
func loadConfigExtras() []string {
	path := os.Getenv(envConfigPath)
	if path == "" {
		return nil
	}
	var c allowlistConfig
	if _, err := toml.DecodeFile(path, &c); err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "git-allowlist: %s: %v\n", path, err)
		}
		return nil
	}
	return c.Allow
}

func isGit(name string) bool { return path.Base(name) == "git" }
