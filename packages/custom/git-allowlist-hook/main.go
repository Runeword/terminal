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
// (literal "git" or any path basename "git") is checked. The check verifies
// the subcommand against defaultAllowedSubcommands (or the
// CLAUDE_GIT_ALLOWLIST_CONFIG TOML extension), and additionally denies the
// avenues that turn an allowed read subcommand into code execution:
//
//   - the global flags `-c key=value`, `--config-env` and `--exec-path`, which
//     inject config (e.g. core.fsmonitor=<cmd>) or redirect git's helper path;
//   - an exec-capable environment assignment on the call itself
//     (`GIT_EXTERNAL_DIFF=cmd git diff`, `GIT_PAGER=cmd /usr/bin/git log`); and
//   - `git config` write/edit forms (only reads are allowed).
//
// Subcommand-specific flags past the subcommand are NOT inspected: allowlisting
// a subcommand trusts all of its flags. The hook does *not* recurse into
// `bash -c '...'`, `eval '...'`, heredoc bodies, or prefix wrappers like
// `xargs git X` / `env FOO=x git X` / `nice git X` — those forms pass through
// this hook untouched. The PATH-based git shim in packages/custom/git-shim is
// the layer that catches them, at exec time, by virtue of being installed first
// on PATH (and it also strips the exec-capable environment).
//
// This hook's unique value over the shim is catching absolute-path git calls
// (`/usr/bin/git push`) that appear as direct bash command words — the shim is
// bypassed by absolute paths because PATH lookup is skipped. For the same
// reason the hook (not the shim) is what denies exec-capable env assignments on
// an absolute-path git call: the shim never runs, so it cannot strip them.
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
	// Global git flags that consume the next argument as their value but are
	// safe (they relocate the repo/cwd). We skip past these to find the
	// subcommand; we do not inspect their values.
	globalFlagsWithArg = map[string]struct{}{
		"-C": {}, "--git-dir": {}, "--work-tree": {}, "--namespace": {},
	}
	// Global flags that can inject command execution (config keys or helper
	// path) and are therefore denied outright. See git-shim for the rationale.
	execInjectingFlags = map[string]struct{}{
		"-c": {}, "--config-env": {}, "--exec-path": {},
	}
)

// git config read/write classification (see gitConfigIsWrite).
var (
	gitConfigWriteSubcommands = map[string]struct{}{
		"set": {}, "unset": {}, "unset-all": {}, "add": {}, "replace-all": {},
		"rename-section": {}, "remove-section": {}, "edit": {},
	}
	gitConfigReadSubcommands = map[string]struct{}{
		"get": {}, "get-all": {}, "get-regexp": {}, "get-urlmatch": {}, "list": {},
	}
	gitConfigWriteFlags = map[string]struct{}{
		"--add": {}, "--replace-all": {}, "--unset": {}, "--unset-all": {},
		"--rename-section": {}, "--remove-section": {}, "--edit": {}, "-e": {},
	}
	gitConfigValueFlags = map[string]struct{}{
		"--file": {}, "-f": {}, "--blob": {}, "--default": {}, "--type": {}, "-t": {},
	}
)

// dangerousGitEnv are environment variable names that let git execute arbitrary
// commands or inject config. As an assignment prefix on a direct git call they
// are denied (the shim strips them for PATH git, but cannot for absolute-path
// git, which never reaches the shim).
var dangerousGitEnv = map[string]struct{}{
	"GIT_EXTERNAL_DIFF":     {},
	"GIT_SSH":               {},
	"GIT_SSH_COMMAND":       {},
	"GIT_PROXY_COMMAND":     {},
	"GIT_ASKPASS":           {},
	"GIT_EDITOR":            {},
	"GIT_SEQUENCE_EDITOR":   {},
	"GIT_PAGER":             {},
	"PAGER":                 {},
	"GIT_CONFIG":            {},
	"GIT_CONFIG_GLOBAL":     {},
	"GIT_CONFIG_SYSTEM":     {},
	"GIT_CONFIG_COUNT":      {},
	"GIT_CONFIG_PARAMETERS": {},
}

var dangerousGitEnvPrefixes = []string{
	"GIT_CONFIG_KEY_",
	"GIT_CONFIG_VALUE_",
}

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
		if err := checkGitCall(call); err != nil {
			policyErr = err
			return false
		}
		return true
	})
	return policyErr
}

// checkGitCall verifies a direct git CallExpr: it rejects exec-capable
// environment assignments and global flags, finds the subcommand past any
// leading global flags, and verifies it against the allowlist (read-only for
// `config`).
func checkGitCall(call *syntax.CallExpr) error {
	// Exec-capable env assignments on the call itself, e.g.
	// `GIT_EXTERNAL_DIFF=cmd git diff`. The shim strips these for PATH-resolved
	// git, but an absolute-path git never reaches the shim, so deny here.
	for _, a := range call.Assigns {
		if a.Name != nil && isDangerousGitEnv(a.Name.Value) {
			return fmt.Errorf("environment assignment %q can inject command execution into git", a.Name.Value)
		}
	}

	args := call.Args[1:]
	i := 0
	for i < len(args) {
		tok, ok := wordLiteral(args[i])
		if !ok || !strings.HasPrefix(tok, "-") {
			break
		}
		name, _, hasValue := splitFlag(tok)
		if _, bad := execInjectingFlags[name]; bad {
			return fmt.Errorf("global flag %q can inject command execution and is not allowed", name)
		}
		if _, takesArg := globalFlagsWithArg[name]; takesArg && !hasValue {
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
	if sub == "config" {
		rest, ok := literalArgs(args[i+1:])
		if !ok || gitConfigIsWrite(rest) {
			return errors.New(`"git config" write/edit forms are not allowed (read-only config only)`)
		}
	}
	return nil
}

// isDangerousGitEnv reports whether an environment variable name is one of the
// exec-capable / config-injecting git variables.
func isDangerousGitEnv(name string) bool {
	if _, ok := dangerousGitEnv[name]; ok {
		return true
	}
	for _, p := range dangerousGitEnvPrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

// splitFlag splits a flag token of the form `--name=value` (or `-c=value`)
// into its name, value, and whether the `=` was present.
func splitFlag(tok string) (name, value string, hasValue bool) {
	if eq := strings.IndexByte(tok, '='); eq >= 0 {
		return tok[:eq], tok[eq+1:], true
	}
	return tok, "", false
}

// literalArgs resolves a slice of words to their literal string values. ok is
// false if any word contains an expansion (so its value cannot be statically
// known) — callers treat that as a reason to fail closed.
func literalArgs(words []*syntax.Word) ([]string, bool) {
	out := make([]string, 0, len(words))
	for _, w := range words {
		s, ok := wordLiteral(w)
		if !ok {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}

// gitConfigIsWrite reports whether a `git config` invocation (args are the
// tokens after "config") would create, change, delete, or open-in-editor any
// configuration — i.e. anything other than a pure read. Classification errs
// toward "write" when ambiguous, since a write is the dangerous case.
func gitConfigIsWrite(args []string) bool {
	positionals := 0
	firstPositional := ""
	for i := 0; i < len(args); i++ {
		tok := args[i]
		if strings.HasPrefix(tok, "-") {
			name, _, hasValue := splitFlag(tok)
			if _, ok := gitConfigWriteFlags[name]; ok {
				return true
			}
			if _, ok := gitConfigValueFlags[name]; ok && !hasValue {
				i++ // skip the value so it is not counted as a positional
			}
			continue
		}
		if positionals == 0 {
			firstPositional = tok
		}
		positionals++
	}
	if _, ok := gitConfigWriteSubcommands[firstPositional]; ok {
		return true
	}
	if _, ok := gitConfigReadSubcommands[firstPositional]; ok {
		return false
	}
	// Classic form: `git config <name>` reads, `git config <name> <value>` writes.
	return positionals >= 2
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
