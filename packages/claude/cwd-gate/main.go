// Command claude-cwd-gate decides whether claude-sandbox.bash may bind the
// current working directory read-write into the bubblewrap namespace. It refuses
// — printing the reason and exiting 64 — when the physical cwd *contains* $HOME,
// an XDG config/data root, or ~/.local (binding it read-write would hand the
// namespace the whole home directory: a no-op sandbox), or when the cwd lies
// *inside* a tree the desktop session executes at login (~/.config/systemd,
// ~/.config/autostart, ~/.local/share/systemd, ~/.local/share/applications,
// ~/.local/bin), where read-write access is host code execution at the next login.
//
// The launcher resolves the physical cwd itself (cd -P) and passes it as --pwd, so
// there is a single cwd resolver; this binary only canonicalises the sensitive
// directories (like readlink -m) and runs the prefix tests. On any exit other
// than 0 the launcher aborts (fail closed). See
// sources/.config/shell/scripts/claude-sandbox.bash.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// exitRefused mirrors the launcher's `exit 64` for a rejected cwd.
const exitRefused = 64

// checkGate returns a refusal reason if pwd must not be bound read-write.
// contains are sensitive dirs the cwd may not be an ancestor of (or equal to);
// inside are login-exec dirs the cwd may not sit within. Both lists are already
// canonical; pwd is already physical (the launcher's cd -P).
func checkGate(pwd string, contains, inside []string) (string, bool) {
	pwdSlash := strings.TrimRight(pwd, "/") + "/"
	for _, b := range contains {
		if strings.HasPrefix(b+"/", pwdSlash) {
			return fmt.Sprintf("refusing to bind %s read-write — it contains %s; run from a project directory (or CLAUDE_SANDBOX=0 to launch unsandboxed)", pwd, b), true
		}
	}
	for _, b := range inside {
		if strings.HasPrefix(pwdSlash, b+"/") {
			return fmt.Sprintf("refusing to bind %s read-write — it is inside %s, which your desktop session executes at login (or CLAUDE_SANDBOX=0 to launch unsandboxed)", pwd, b), true
		}
	}
	return "", false
}

// resolveM canonicalises path like `readlink -m`: it resolves symlinks in the
// longest existing prefix and appends the cleaned, non-existent remainder,
// without requiring the whole path to exist — matching how the launcher's
// readlink -m canonicalised each sensitive directory before the prefix test.
func resolveM(path string) string {
	clean := filepath.Clean(path)
	var rem []string
	p := clean
	for {
		if resolved, err := filepath.EvalSymlinks(p); err == nil {
			for i := len(rem) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, rem[i])
			}
			return resolved
		}
		parent := filepath.Dir(p)
		if parent == p {
			return clean
		}
		rem = append(rem, filepath.Base(p))
		p = parent
	}
}

func main() {
	pwd := flag.String("pwd", "", "physical current working directory (from cd -P)")
	home := flag.String("home", "", "value of $HOME")
	config := flag.String("config", "", "effective XDG_CONFIG_HOME")
	data := flag.String("data", "", "effective XDG_DATA_HOME")
	flag.Parse()

	if *pwd == "" || *home == "" || *config == "" || *data == "" {
		fmt.Fprintln(os.Stderr, "claude-cwd-gate: --pwd, --home, --config and --data are required")
		os.Exit(2)
	}

	contains := []string{*home, *config, *data, filepath.Join(*home, ".local")}
	inside := []string{
		filepath.Join(*config, "systemd"),
		filepath.Join(*config, "autostart"),
		filepath.Join(*data, "systemd"),
		filepath.Join(*data, "applications"),
		filepath.Join(*home, ".local", "bin"),
	}
	for i := range contains {
		contains[i] = resolveM(contains[i])
	}
	for i := range inside {
		inside[i] = resolveM(inside[i])
	}

	if msg, refused := checkGate(*pwd, contains, inside); refused {
		fmt.Fprintln(os.Stderr, "claude-sandbox: "+msg)
		os.Exit(exitRefused)
	}
}
