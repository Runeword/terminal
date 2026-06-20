// Command git is a PATH shim that denies any git invocation whose subcommand
// is not in the allowlist, and otherwise exec's the real git binary. It is
// installed first on PATH for the Claude Code session by the claude wrapper,
// so any PATH-resolved `git` call (from bash, Python subprocess, Make, …)
// passes through the shim before reaching the real binary.
//
// # Policy
//
// The first non-flag positional argument is the subcommand. If it is in
// defaultAllowed (or the CLAUDE_GIT_ALLOWLIST_CONFIG TOML extension) the call
// is permitted; otherwise it is denied. On top of the subcommand check the
// shim closes the avenues that turn an *allowed* (read-only) subcommand into
// arbitrary code execution:
//
//   - Global flags that inject config or relocate git's helper search path
//     (`-c key=value`, `--config-env`, `--exec-path`) are rejected. They let
//     `git -c core.fsmonitor=<cmd> status` run <cmd> through a read subcommand.
//   - Exec-capable environment variables (GIT_EXTERNAL_DIFF, GIT_SSH_COMMAND,
//     GIT_PAGER, GIT_CONFIG_*, editors, askpass, …) are stripped from the
//     environment before exec, and GIT_PAGER is forced to `cat` so neither the
//     environment nor a malicious core.pager in on-disk config can run a pager
//     command.
//   - `git config` is permitted for reads only; any write/edit form is denied,
//     since a single `git config core.pager '!cmd'` plants persistent code
//     execution that fires on the next allowed read.
//
// Subcommand-specific flags past the subcommand are NOT inspected: allowlisting
// a subcommand trusts all of its flags (e.g. allowing `push` allows
// `push --force`). Residual, out of scope here: an attacker who can already
// write files can plant exec-capable keys in a repo's own .git/config, or
// invoke an absolute-path git through a wrapper the shim never sees
// (`env … /usr/bin/git …`); those require a separate write/exec primitive.
package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"syscall"

	"github.com/BurntSushi/toml"
)

// realGit is the absolute path to the real git binary. Set at build time via
// `-ldflags "-X main.realGit=${pkgs.git}/bin/git"`.
var realGit string

const envConfigPath = "CLAUDE_GIT_ALLOWLIST_CONFIG"

var (
	defaultAllowed = map[string]struct{}{
		"status": {}, "diff": {}, "log": {}, "show": {}, "branch": {},
		"rev-parse": {}, "config": {}, "remote": {}, "ls-files": {}, "blame": {},
	}
	// Global flags that consume the next argv as their value but are safe (they
	// relocate the repo/cwd, they do not execute anything). We skip past these
	// so the subcommand check sees the subcommand, not the flag's value.
	globalFlagsWithArg = map[string]struct{}{
		"-C": {}, "--git-dir": {}, "--work-tree": {}, "--namespace": {},
	}
	// Global flags that can inject command execution: `-c name=value` sets an
	// arbitrary config key (e.g. core.fsmonitor=<cmd>), `--config-env` does the
	// same sourcing the value from an env var, and `--exec-path` redirects where
	// git looks for its helper programs. None has a legitimate use in a
	// read-only allowlist, so any of them is a deny.
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
	// config flags that consume the next token as a value; tracked so the value
	// is not miscounted as a positional argument (which would flip the
	// read-vs-write classification).
	gitConfigValueFlags = map[string]struct{}{
		"--file": {}, "-f": {}, "--blob": {}, "--default": {}, "--type": {}, "-t": {},
	}
)

// dangerousGitEnv are environment variables that let git execute arbitrary
// commands (editors, pagers, diff/ssh/proxy/askpass helpers) or inject config
// (GIT_CONFIG_*). They are stripped before exec so an allowed read subcommand
// cannot be turned into code execution through the environment.
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

// dangerousGitEnvPrefixes covers the numbered GIT_CONFIG_KEY_<n> /
// GIT_CONFIG_VALUE_<n> family, which is equivalent to a string of `-c` flags.
var dangerousGitEnvPrefixes = []string{
	"GIT_CONFIG_KEY_",
	"GIT_CONFIG_VALUE_",
}

func main() {
	if realGit == "" {
		fmt.Fprintln(os.Stderr, "git-shim: realGit not configured at build time")
		os.Exit(128)
	}
	args := os.Args[1:]
	if err := check(args); err != nil {
		fmt.Fprintf(os.Stderr, "git-shim: denied: %v\n", err)
		os.Exit(128)
	}
	env := sanitizeEnv(os.Environ())
	if err := syscall.Exec(realGit, append([]string{"git"}, args...), env); err != nil {
		fmt.Fprintf(os.Stderr, "git-shim: exec %s: %v\n", realGit, err)
		os.Exit(128)
	}
}

// check finds the subcommand past any leading global flags, rejecting any
// exec-injecting global flag along the way, and verifies the subcommand against
// the allowlist (with a read-only restriction for `config`).
func check(args []string) error {
	i := 0
	for i < len(args) {
		tok := args[i]
		if !strings.HasPrefix(tok, "-") {
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
	sub := args[i]
	if !isAllowed(sub) {
		return fmt.Errorf("%q is not in the allowlist", "git "+sub)
	}
	if sub == "config" && gitConfigIsWrite(args[i+1:]) {
		return errors.New(`"git config" write/edit forms are not allowed (read-only config only)`)
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

// sanitizeEnv returns env with the exec-capable git variables removed and
// GIT_PAGER forced to a non-executing pager. GIT_PAGER=cat is the
// highest-precedence pager source, so it also overrides a malicious core.pager
// set in any on-disk config.
func sanitizeEnv(env []string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		name := kv
		if eq := strings.IndexByte(kv, '='); eq >= 0 {
			name = kv[:eq]
		}
		if _, bad := dangerousGitEnv[name]; bad {
			continue
		}
		if hasAnyPrefix(name, dangerousGitEnvPrefixes) {
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "GIT_PAGER=cat")
	return out
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func isAllowed(sub string) bool {
	if _, ok := defaultAllowed[sub]; ok {
		return true
	}
	for _, name := range loadExtras() {
		if name == sub {
			return true
		}
	}
	return false
}

type allowlistConfig struct {
	Allow []string `toml:"allow"`
}

// loadExtras returns the user's per-project additions from the TOML file at
// CLAUDE_GIT_ALLOWLIST_CONFIG. Unset/missing/malformed → no extras (with a
// stderr note on parse error so a broken config is visible).
func loadExtras() []string {
	p := os.Getenv(envConfigPath)
	if p == "" {
		return nil
	}
	var c allowlistConfig
	if _, err := toml.DecodeFile(p, &c); err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "git-shim: %s: %v\n", p, err)
		}
		return nil
	}
	return c.Allow
}
