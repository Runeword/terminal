// Command git is a PATH shim that denies any git invocation whose subcommand
// is not in the allowlist, and otherwise exec's the real git binary. It is
// installed first on PATH for the Claude Code session by the claude wrapper,
// so any PATH-resolved `git` call (from bash, Python subprocess, Make, …)
// passes through the shim before reaching the real binary.
//
// Policy: the first non-flag positional argument is the subcommand. If it is
// in defaultAllowed (or in the CLAUDE_GIT_ALLOWLIST_CONFIG TOML extension),
// the call exec's real git unchanged. Otherwise it denies. No flag inspection,
// no config-key blocking, no config-write detection — git's own surface is
// trusted past the subcommand check.
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
	// Global flags that consume the next argv as their value (`git -C /path
	// log`). We skip past these so the subcommand check sees `log`, not `-C`.
	// We do *not* inspect their values — this is a subcommand allowlist, not
	// an RCE-aware policy.
	globalFlagsWithArg = map[string]struct{}{
		"-C": {}, "-c": {}, "--git-dir": {}, "--work-tree": {},
		"--namespace": {}, "--config-env": {},
	}
)

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
	if err := syscall.Exec(realGit, append([]string{"git"}, args...), os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "git-shim: exec %s: %v\n", realGit, err)
		os.Exit(128)
	}
}

// check finds the subcommand past any leading global flags and verifies it
// against the allowlist.
func check(args []string) error {
	for i := 0; i < len(args); i++ {
		tok := args[i]
		if !strings.HasPrefix(tok, "-") {
			if isAllowed(tok) {
				return nil
			}
			return fmt.Errorf("%q is not in the allowlist", "git "+tok)
		}
		// `--flag=value` form: the value is inlined, no further skip needed.
		if strings.Contains(tok, "=") {
			continue
		}
		// `-C path`, `-c key=value`, etc.: skip the value too.
		if _, takesArg := globalFlagsWithArg[tok]; takesArg {
			i++
		}
	}
	return errors.New("git invoked without a subcommand")
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
