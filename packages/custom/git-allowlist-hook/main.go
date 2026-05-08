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
		"--namespace": {}, "--config-env": {},
	}
	// Global flags that are always denied: they let the caller substitute
	// an arbitrary git binary or otherwise bypass the allowlist machinery.
	alwaysDeniedGlobalFlags = map[string]struct{}{
		"--exec-path": {},
	}
	// Config keys (lowercased) that, if injected via -c / --config-env, cause
	// git to execute arbitrary commands during otherwise-allowed subcommands
	// (pager, fsmonitor, signing helpers, etc.).
	dangerousConfigKeys = map[string]struct{}{
		"core.pager":          {},
		"core.fsmonitor":      {},
		"core.editor":         {},
		"core.sshcommand":     {},
		"core.askpass":        {},
		"core.hookspath":      {},
		"core.gitproxy":       {},
		"gpg.program":         {},
		"gpg.openpgp.program": {},
		"gpg.x509.program":    {},
		"gpg.ssh.program":     {},
		"diff.external":       {},
		"merge.tool":          {},
		"http.proxy":          {},
		"init.templatedir":    {},
		"safe.directory":      {},
	}
	dangerousConfigKeyPrefixes = []string{
		"alias.",      // !shell aliases
		"filter.",     // filter.<name>.{clean,smudge,process}
		"difftool.",   // difftool.<name>.cmd
		"mergetool.",  // mergetool.<name>.cmd
		"pager.",      // pager.<cmd>
		"url.",        // url rewriting -> SSRF / redirect
		"credential.", // credential helpers
		"protocol.",   // protocol allow/deny
	}
	// `git config` flags that mutate config — denied so the allowlist itself
	// can't be undermined (e.g. by writing a `!shell` alias).
	configWriteFlags = map[string]struct{}{
		"--add":            {},
		"--unset":          {},
		"--unset-all":      {},
		"--replace-all":    {},
		"--rename-section": {},
		"--remove-section": {},
		"--edit":           {},
		"-e":               {},
	}
	// `git config` flags that explicitly indicate a read; their presence
	// suppresses the positional-count heuristic, which would otherwise flag
	// e.g. `--get-regexp pat val` as a write.
	configReadFlags = map[string]struct{}{
		"--get":           {},
		"--get-all":       {},
		"--get-regexp":    {},
		"--get-urlmatch":  {},
		"--get-color":     {},
		"--get-colorbool": {},
		"--list":          {},
		"-l":              {},
	}
	// `git config` flags whose value lives in the next argv (`--type int`).
	// Tracked so we don't miscount the value as a positional.
	configFlagsWithArg = map[string]struct{}{
		"-f":        {},
		"--file":    {},
		"--blob":    {},
		"-t":        {},
		"--type":    {},
		"--default": {},
		"--comment": {},
		"--value":   {},
	}
	// Shells whose `-c <script>` argument we recursively parse.
	shellRunners = map[string]struct{}{
		"bash": {}, "sh": {}, "zsh": {}, "dash": {}, "ash": {},
	}
	// Command-prefix wrappers (xargs, env, ...) — programs that consume
	// some leading flags and then exec a child command. We strip the
	// wrapper's own flags and recursively check the inner command.
	prefixCommands = map[string]prefixSpec{
		"xargs": {
			flagsWithArg: map[string]struct{}{
				"-I": {}, "-J": {}, "-L": {}, "-n": {}, "-P": {},
				"-s": {}, "-d": {}, "-E": {}, "-e": {}, "-a": {},
				"--max-args": {}, "--max-procs": {}, "--max-chars": {},
				"--max-lines": {}, "--replace": {}, "--delimiter": {},
				"--eof": {}, "--arg-file": {},
			},
		},
		"env": {
			flagsWithArg: map[string]struct{}{
				"-u": {}, "--unset": {}, "-S": {}, "--split-string": {},
				"-C": {}, "--chdir": {},
			},
			skipKeyValue: true,
		},
		"nice": {
			flagsWithArg: map[string]struct{}{"-n": {}, "--adjustment": {}},
		},
		"timeout": {
			flagsWithArg: map[string]struct{}{
				"-s": {}, "--signal": {}, "-k": {}, "--kill-after": {},
			},
			skipPositionals: 1,
		},
		"command": {},
		"exec": {
			flagsWithArg: map[string]struct{}{"-a": {}},
		},
		"stdbuf": {
			flagsWithArg: map[string]struct{}{"-i": {}, "-o": {}, "-e": {}},
		},
	}
)

type prefixSpec struct {
	flagsWithArg    map[string]struct{}
	skipPositionals int
	skipKeyValue    bool
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
		if err := checkCall(first, call.Args[1:]); err != nil {
			policyErr = err
			return false
		}
		return true
	})
	return policyErr
}

// checkCall dispatches a single command invocation by leading binary name.
// Unknown commands pass through; this is policy by allowlist of git, not by
// denylist of everything else.
func checkCall(name string, args []*syntax.Word) error {
	switch {
	case isGit(name):
		return checkGitCall(args)
	case isShellRunner(name):
		for _, script := range extractShellScripts(args) {
			if err := checkCommand(script); err != nil {
				return err
			}
		}
	case isEval(name):
		return checkEvalCall(args)
	case isPrefixCommand(name):
		return checkPrefixCall(name, args)
	}
	return nil
}

func checkGitCall(args []*syntax.Word) error {
	i := 0
	for i < len(args) {
		tok, ok := wordLiteral(args[i])
		if !ok || !strings.HasPrefix(tok, "-") {
			break
		}
		flag, value, hasValue := splitFlag(tok)
		if _, denied := alwaysDeniedGlobalFlags[flag]; denied {
			return fmt.Errorf("forbidden global flag %s", flag)
		}
		if _, takesArg := globalFlagsWithArg[flag]; takesArg {
			if !hasValue {
				if i+1 >= len(args) {
					return fmt.Errorf("global flag %s missing argument", flag)
				}
				if v, vok := wordLiteral(args[i+1]); vok {
					value = v
					hasValue = true
				}
				i += 2
			} else {
				i++
			}
			if hasValue && (flag == "-c" || flag == "--config-env") {
				if err := checkConfigOverride(value); err != nil {
					return err
				}
			}
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
	rest := args[i+1:]
	if err := checkForbiddenFlags(rest); err != nil {
		return err
	}
	if sub == "config" {
		if err := checkConfigSubcommand(rest); err != nil {
			return err
		}
	}
	return nil
}

func checkForbiddenFlags(args []*syntax.Word) error {
	for _, w := range args {
		tok, ok := wordLiteral(w)
		if !ok {
			continue
		}
		if tok == "--" {
			break
		}
		flag, _, _ := splitFlag(tok)
		if _, bad := forbiddenFlags[flag]; bad {
			return fmt.Errorf("forbidden flag %s", flag)
		}
	}
	return nil
}

// checkConfigOverride inspects a `-c key=value` (or `--config-env=key=envvar`)
// argument and rejects keys that cause git to execute commands.
func checkConfigOverride(kv string) error {
	key := kv
	if eq := strings.IndexByte(kv, '='); eq >= 0 {
		key = kv[:eq]
	}
	key = strings.ToLower(key)
	if _, dangerous := dangerousConfigKeys[key]; dangerous {
		return fmt.Errorf("forbidden config override %s", key)
	}
	for _, prefix := range dangerousConfigKeyPrefixes {
		if strings.HasPrefix(key, prefix) {
			return fmt.Errorf("forbidden config override %s", key)
		}
	}
	return nil
}

// checkConfigSubcommand rejects `git config` invocations that mutate config.
// Either an explicit write flag (--add, --unset, ...) or two-or-more
// positionals without a read flag indicates a write.
func checkConfigSubcommand(args []*syntax.Word) error {
	var positionals int
	var hasReadFlag bool
	skipNext := false
	for i := 0; i < len(args); i++ {
		if skipNext {
			skipNext = false
			continue
		}
		tok, ok := wordLiteral(args[i])
		if !ok {
			continue
		}
		if tok == "--" {
			for _, rest := range args[i+1:] {
				if _, ok := wordLiteral(rest); ok {
					positionals++
				}
			}
			break
		}
		if !strings.HasPrefix(tok, "-") {
			positionals++
			continue
		}
		flag, _, hasEq := splitFlag(tok)
		if _, write := configWriteFlags[flag]; write {
			return fmt.Errorf("forbidden git config flag %s (writes config)", flag)
		}
		if _, read := configReadFlags[flag]; read {
			hasReadFlag = true
		}
		if !hasEq {
			if _, takesArg := configFlagsWithArg[flag]; takesArg {
				skipNext = true
			}
		}
	}
	if !hasReadFlag && positionals >= 2 {
		return errors.New("git config with 2+ positional args is a write")
	}
	return nil
}

// checkEvalCall reconstructs eval's command string and recursively checks it.
// Eval with any non-literal argument cannot be statically analysed, so it is
// denied (consistent with how `git $sub` is treated).
func checkEvalCall(args []*syntax.Word) error {
	if len(args) == 0 {
		return nil
	}
	parts := make([]string, 0, len(args))
	for _, w := range args {
		s, ok := wordLiteral(w)
		if !ok {
			return errors.New("eval with non-literal argument")
		}
		parts = append(parts, s)
	}
	return checkCommand(strings.Join(parts, " "))
}

// checkPrefixCall handles command-prefix wrappers (xargs, env, nice, timeout,
// command, exec, stdbuf): strip the wrapper's own flags, then dispatch the
// inner command back through checkCall.
func checkPrefixCall(name string, args []*syntax.Word) error {
	spec := prefixCommands[path.Base(name)]
	inner := stripPrefixFlags(spec, args)
	if len(inner) == 0 {
		return nil
	}
	innerName, ok := wordLiteral(inner[0])
	if !ok {
		return nil
	}
	return checkCall(innerName, inner[1:])
}

func stripPrefixFlags(spec prefixSpec, args []*syntax.Word) []*syntax.Word {
	i := 0
	for i < len(args) {
		tok, ok := wordLiteral(args[i])
		if !ok {
			return nil
		}
		if tok == "--" {
			i++
			break
		}
		if !strings.HasPrefix(tok, "-") {
			if spec.skipKeyValue && strings.Contains(tok, "=") {
				i++
				continue
			}
			break
		}
		if strings.Contains(tok, "=") {
			i++
			continue
		}
		if _, takesArg := spec.flagsWithArg[tok]; takesArg {
			i += 2
			continue
		}
		i++
	}
	for k := 0; k < spec.skipPositionals && i < len(args); k++ {
		i++
	}
	if i >= len(args) {
		return nil
	}
	return args[i:]
}

// extractShellScripts returns the script strings passed to a shell via -c-style
// flags. Handles bare `-c`, combined-short-flag bundles ending in c (-ec, -uec,
// ...), and multiple -c flags in the same invocation.
func extractShellScripts(args []*syntax.Word) []string {
	var scripts []string
	for i := 0; i < len(args)-1; i++ {
		tok, ok := wordLiteral(args[i])
		if !ok {
			continue
		}
		if !looksLikeDashC(tok) {
			continue
		}
		if next, ok := wordLiteral(args[i+1]); ok {
			scripts = append(scripts, next)
		}
	}
	return scripts
}

// looksLikeDashC reports whether tok is `-c` or a combined-short-flag bundle
// ending in c (e.g. `-ec`, `-uec`). Long --options are excluded.
func looksLikeDashC(tok string) bool {
	if len(tok) < 2 || !strings.HasPrefix(tok, "-") {
		return false
	}
	if strings.HasPrefix(tok, "--") {
		return false
	}
	return strings.HasSuffix(tok, "c")
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

func isEval(name string) bool { return path.Base(name) == "eval" }

func isPrefixCommand(name string) bool {
	_, ok := prefixCommands[path.Base(name)]
	return ok
}
