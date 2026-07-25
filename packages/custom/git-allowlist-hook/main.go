// Command git-allowlist-hook is a Claude Code PreToolUse hook that denies any
// Bash-tool command which directly invokes git with a subcommand outside a
// small read-only allowlist. It emits a structured PreToolUse
// permissionDecision JSON document on stdout. Any internal error (malformed
// input, unparseable shell) maps to a deny, so the hook fails closed on
// parsing errors.
//
// # Policy
//
// The bash AST is walked and every command invocation is classified:
//
//   - A direct git call — Args[0] is "git" or any path whose basename is "git"
//     (e.g. "/usr/bin/git") — is checked: its subcommand must be in
//     defaultAllowedSubcommands (or the CLAUDE_GIT_ALLOWLIST_CONFIG TOML
//     extension), and the avenues that turn an allowed subcommand into code
//     execution are denied — the global flags `-c key=value`, `--config-env`,
//     `--exec-path`; subcommand-local flags that run a command (`--upload-pack`,
//     `--receive-pack`, `--exec`; rebase `-x`/`-i`; grep `-O`); an exec-capable
//     environment assignment on the call (`GIT_EXTERNAL_DIFF=cmd git diff`); and
//     `git config` write/edit forms.
//
//   - A git call smuggled behind a command runner is denied. `env`, `sudo`,
//     `doas` and `command` can run git under a reset or non-standard PATH
//     (sudo's secure_path, `command -p`), so any git argument — bare or a
//     slashed path — is denied. PATH-preserving runners (`xargs`, `nice`,
//     `timeout`, `nohup`, `flock`, …) still resolve a bare `git` through the
//     PATH shim, so for them only a *slashed* git path (which skips the shim)
//     is denied — a bare `git` word (e.g. as a grep pattern) is left alone.
//
//   - A command string passed to a shell with -c (`bash -c "/usr/bin/git
//     push"`) or to `eval` is re-parsed and re-checked under the same policy.
//
// Subcommand-specific flags past an allowed subcommand are NOT inspected:
// allowlisting a subcommand trusts all of its flags.
//
// # Relationship to the PATH git shim
//
// This hook and the PATH-based git shim (packages/custom/git-shim) are
// complementary. The shim catches git resolved through PATH and strips
// exec-capable git environment variables at exec time, by virtue of being
// installed first on PATH. The hook catches what the shim cannot see: git
// invoked by an absolute/slashed path (PATH lookup is skipped, so the shim
// never runs), including such a path smuggled behind a wrapper or a `-c`
// string. A bare `git` run by a PATH-preserving wrapper stays the shim's
// responsibility; the hook does not duplicate it (and cannot, without
// re-implementing each wrapper's argument grammar). Not inspected by this hook:
// heredoc bodies, script files (`bash script.sh`), deeper wrapper/shell
// nestings, and dynamic strings whose value is not statically known.
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
	// Subcommand-local flags that run an arbitrary command under every
	// subcommand that accepts them, so they are denied after any allowed
	// subcommand: --upload-pack/--receive-pack name the program that "serves" a
	// fetch/push (git fetch --upload-pack=<cmd> runs <cmd> locally); --exec is
	// rebase's per-commit exec and push's --receive-pack alias.
	execFlagNames = map[string]struct{}{
		"--upload-pack": {}, "--receive-pack": {}, "--exec": {},
	}
	// Flags that are exec-capable only for a specific subcommand and benign
	// elsewhere (grep -i is case-insensitive, diff -O is an orderfile), matched
	// per subcommand. Letters match inside a short-flag cluster (-ix, -Ocmd).
	execFlagNamesBySub = map[string]map[string]struct{}{
		"rebase": {"--interactive": {}},
		"grep":   {"--open-files-in-pager": {}},
	}
	execFlagLettersBySub = map[string]string{
		"rebase": "xi", // -x runs a command per commit; -i opens the editor
		"grep":   "O",  // -O opens matches in an arbitrary pager command
	}
)

// Command runners that can hide a git invocation from the Args[0] check. See
// the package doc "Policy" section for how each class is treated.
var (
	// shimBypassRunners can execute git under a reset or non-standard PATH
	// (sudo's secure_path, `command -p`, `env PATH=…`), so even a bare `git`
	// argument can dodge the PATH shim. Any git argument — bare or slashed — is
	// denied.
	shimBypassRunners = map[string]struct{}{
		"sudo": {}, "doas": {}, "command": {}, "env": {},
	}
	// pathRunners exec their target through a normal PATH lookup, so a bare
	// `git` still resolves to the PATH shim and is caught at exec time. Only a
	// git given as a slashed path (which skips the shim) is denied here; a bare
	// `git` word (e.g. `timeout 5 grep git`) is not a git invocation for them.
	pathRunners = map[string]struct{}{
		"xargs": {}, "nice": {}, "nohup": {}, "timeout": {}, "stdbuf": {},
		"setsid": {}, "ionice": {}, "taskset": {}, "chrt": {}, "flock": {},
		"watch": {}, "time": {}, "exec": {}, "strace": {}, "ltrace": {},
		"unbuffer": {},
	}
	// shellRunners run a command string given with -c. That string is opaque to
	// the outer parser, so it is re-parsed and re-checked (this is what catches
	// `bash -c "/usr/bin/git push"`). `eval` is handled likewise in checkCall.
	shellRunners = map[string]struct{}{
		"sh": {}, "bash": {}, "dash": {}, "zsh": {}, "ksh": {},
		"mksh": {}, "ash": {},
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

// gitRemoteReadSubcommands are the `git remote` subcommands that only read.
// Everything else (add/remove/rename/set-url/set-head/set-branches/prune/
// update, or anything unrecognised) mutates a remote or refs — see
// gitRemoteIsWrite.
var gitRemoteReadSubcommands = map[string]struct{}{
	"show": {}, "get-url": {},
}

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
		if err := checkCall(call); err != nil {
			policyErr = err
			return false
		}
		return true
	})
	return policyErr
}

// checkCall classifies and checks a single command invocation. A direct git
// call is policy-checked; a git call smuggled behind a command runner (`env`,
// `sudo`, `xargs`, …) or inside a shell `-c` / `eval` string — forms that would
// otherwise slip past the Args[0] check, and, when the git path is slashed,
// past the PATH shim too — is denied or recursively re-checked.
func checkCall(call *syntax.CallExpr) error {
	exe, ok := wordLiteral(call.Args[0])
	if !ok {
		// Dynamic executable (e.g. `$tool push`): nothing to classify
		// statically. Left to the PATH shim, as before.
		return nil
	}
	switch base := path.Base(exe); {
	case base == "git":
		return checkGitCall(call)
	case inSet(shimBypassRunners, base):
		return denyWrappedGit(call, base, false)
	case inSet(pathRunners, base):
		return denyWrappedGit(call, base, true)
	case base == "eval":
		return checkEvalCall(call)
	case inSet(shellRunners, base):
		return checkShellCall(call)
	}
	return nil
}

// denyWrappedGit denies a command runner that carries a git invocation among
// its arguments. When slashedOnly is set the runner preserves PATH, so a bare
// `git` still reaches the PATH shim and only a slashed git path (which skips
// the shim) is treated as a bypass; otherwise any git argument is denied.
func denyWrappedGit(call *syntax.CallExpr, runner string, slashedOnly bool) error {
	for _, arg := range call.Args[1:] {
		tok, ok := wordLiteral(arg)
		if !ok {
			continue
		}
		if path.Base(tok) != "git" {
			continue
		}
		if slashedOnly && !strings.ContainsRune(tok, '/') {
			continue
		}
		return fmt.Errorf("git invoked via %q bypasses the subcommand allowlist and is not allowed", runner)
	}
	return nil
}

// checkEvalCall re-checks the command that `eval` would run: its arguments
// joined by spaces, re-parsed under the same policy. A dynamic argument makes
// the result unknowable, so it is left to the shim (unchanged behaviour).
func checkEvalCall(call *syntax.CallExpr) error {
	parts, ok := literalArgs(call.Args[1:])
	if !ok {
		return nil
	}
	return checkCommand(strings.Join(parts, " "))
}

// checkShellCall re-checks the command string passed to a shell via -c (e.g.
// `bash -c "/usr/bin/git push"`), re-parsing it under the same policy. Only a
// statically literal string is inspected; a dynamic one is left to the shim.
func checkShellCall(call *syntax.CallExpr) error {
	args := call.Args[1:]
	for i, arg := range args {
		tok, ok := wordLiteral(arg)
		if !ok {
			continue
		}
		if !isDashC(tok) {
			continue
		}
		if i+1 >= len(args) {
			return nil
		}
		script, ok := wordLiteral(args[i+1])
		if !ok {
			return nil
		}
		return checkCommand(script)
	}
	return nil
}

// isDashC reports whether tok is a short-option cluster that contains `c`
// (`-c`, `-lc`, `-ec`, …) — the shell flag whose next argument is a command
// string to execute.
func isDashC(tok string) bool {
	if len(tok) < 2 || tok[0] != '-' || tok[1] == '-' {
		return false
	}
	return strings.ContainsRune(tok[1:], 'c')
}

// inSet reports whether k is a member of set.
func inSet(set map[string]struct{}, k string) bool {
	_, ok := set[k]
	return ok
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
	if flag, bad := execCapableFlag(sub, args[i+1:]); bad {
		return fmt.Errorf("git %s flag %q runs an arbitrary command and is not allowed", sub, flag)
	}
	if sub == "config" {
		rest, ok := literalArgs(args[i+1:])
		if !ok || gitConfigIsWrite(rest) {
			return errors.New(`"git config" write/edit forms are not allowed (read-only config only)`)
		}
	}
	if sub == "remote" {
		rest, ok := literalArgs(args[i+1:])
		if !ok || gitRemoteIsWrite(rest) {
			return errors.New(`"git remote" write forms (add/remove/rename/set-url/…) are not allowed (read-only remote only)`)
		}
	}
	return nil
}

// execCapableFlag reports the first subcommand-local flag that would turn an
// (already-allowlisted) subcommand into arbitrary command execution — the
// surface the global -c/--exec-path check does not cover. It is why an
// otherwise-useful subcommand on the allowlist (fetch's --upload-pack, rebase's
// --exec, grep's -O) does not hand back the execution the allowlist removes.
// A standalone "--" ends option scanning; the rest are operands.
func execCapableFlag(sub string, args []*syntax.Word) (string, bool) {
	names := execFlagNamesBySub[sub]
	letters := execFlagLettersBySub[sub]
	for _, w := range args {
		name, ok := wordFlagName(w)
		if !ok {
			continue
		}
		if name == "--" {
			break
		}
		if _, bad := execFlagNames[name]; bad {
			return name, true
		}
		if _, bad := names[name]; bad {
			return name, true
		}
		if letters != "" && isShortCluster(name) && strings.ContainsAny(name[1:], letters) {
			return name, true
		}
	}
	return "", false
}

// wordFlagName returns the flag name of a word when it begins with a literal
// dash — the part before any `=`. It handles fully literal words (including
// quoted forms like "--upload-pack=x") and words whose value is an expansion
// (`--upload-pack=$x`), so a flag cannot hide its name behind quoting or a
// variable. ok is false when the word does not begin with a literal `-`.
func wordFlagName(w *syntax.Word) (string, bool) {
	if s, ok := wordLiteral(w); ok {
		if !strings.HasPrefix(s, "-") {
			return "", false
		}
		name, _, _ := splitFlag(s)
		return name, true
	}
	if len(w.Parts) > 0 {
		if lit, ok := w.Parts[0].(*syntax.Lit); ok && strings.HasPrefix(lit.Value, "-") {
			name, _, _ := splitFlag(lit.Value)
			return name, true
		}
	}
	return "", false
}

// isShortCluster reports whether name is a short-flag token (`-x`, `-ix`) as
// opposed to a long flag (`--foo`) or a non-flag.
func isShortCluster(name string) bool {
	return len(name) >= 2 && name[0] == '-' && name[1] != '-'
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

// gitRemoteIsWrite reports whether a `git remote` invocation (args are the
// tokens after "remote") would create, delete, rename, or repoint a remote (or
// prune/update refs). `git remote` and `git remote -v` list; `show` and
// `get-url` read; every other first positional — add, remove, rm, rename,
// set-url, set-head, set-branches, prune, update, or anything unrecognised — is
// treated as a write (fail closed).
func gitRemoteIsWrite(args []string) bool {
	for _, tok := range args {
		if strings.HasPrefix(tok, "-") {
			continue // -v / --verbose and other list flags
		}
		_, read := gitRemoteReadSubcommands[tok]
		return !read // first positional decides
	}
	return false // no subcommand → lists remotes, read-only
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
