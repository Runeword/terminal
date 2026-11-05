// Command claude-shell-guard runs a command for Claude Code with Claude's
// projects folders read-only. Claude Code keeps its auto memory in
// <config>/projects/<project>/memory/, and the ask rule in settings.json makes
// each memory write by its file tools a permission prompt, but nothing asks
// before a shell command writes there. settings.json names this program in
// CLAUDE_CODE_SHELL_PREFIX, so Claude Code hands it every shell command, hook
// and MCP server it starts, as one argument. It confines itself with Landlock,
// so that neither the command nor anything the command starts can write under
// any <config>/projects, then runs the command with the shell Claude Code would
// have used. Claude Code itself still writes there: transcripts, and memory
// once the user approves.
//
// Landlock only grants access, so writes are granted to every folder and file
// beside the path from / down to each projects folder, and to none on that
// path: a command can change the files already in $HOME or in a config folder,
// but can't create, delete or rename entries directly in them. claude.bash
// makes the caches the plugins keep in the profile before the session starts.
//
// It fails closed: when Landlock or anything else it needs is missing, it
// refuses to run the command (exit 126). On systems other than Linux it runs
// the command as is: there Claude Code's own sandbox already keeps shell
// commands out of the config folders (settings.darwin.json).
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
)

func main() {
	// Landlock and no_new_privs bind the calling thread, which must be the one
	// that execs the shell.
	runtime.LockOSThread()
	if len(os.Args) != 2 {
		fail("usage: claude-shell-guard <command>, as Claude Code's CLAUDE_CODE_SHELL_PREFIX")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		fail(err.Error())
	}
	if err := confine(protectedDirs(home, os.Getenv("CLAUDE_CONFIG_DIR"))); err != nil {
		fail(fmt.Sprintf("refusing to run the command: %v", err))
	}
	shell, err := shellPath(os.Getenv("CLAUDE_CODE_SHELL"), os.Getenv("SHELL"))
	if err != nil {
		fail(err.Error())
	}
	err = syscall.Exec(shell, []string{shell, "-c", os.Args[1]}, os.Environ())
	fail(fmt.Sprintf("running %s: %v", shell, err))
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "claude-shell-guard:", msg)
	os.Exit(126)
}

// protectedDirs lists the projects folders to keep read-only: the one in config
// ($CLAUDE_CONFIG_DIR) and the one in every folder in home named .claude*
// (every profile: ~/.claude, ~/.claude-1, …), whether it exists yet or not,
// with symbolic links resolved.
func protectedDirs(home, config string) []string {
	configs := []string{filepath.Join(home, ".claude")}
	if config != "" {
		if abs, err := filepath.Abs(config); err == nil {
			configs = append(configs, abs)
		}
	}
	if entries, err := os.ReadDir(home); err == nil {
		for _, e := range entries {
			if !strings.HasPrefix(e.Name(), ".claude") {
				continue
			}
			p := filepath.Join(home, e.Name())
			if info, err := os.Stat(p); err == nil && info.IsDir() {
				configs = append(configs, p)
			}
		}
	}
	seen := make(map[string]bool, len(configs))
	var dirs []string
	for _, c := range configs {
		d := resolve(filepath.Join(c, "projects"))
		if !seen[d] {
			seen[d] = true
			dirs = append(dirs, d)
		}
	}
	sort.Strings(dirs)
	return dirs
}

// resolve resolves the symbolic links in the part of path that exists.
func resolve(path string) string {
	rest := ""
	for p := filepath.Clean(path); ; p = filepath.Dir(p) {
		if real, err := filepath.EvalSymlinks(p); err == nil {
			return filepath.Join(real, rest)
		}
		if p == filepath.Dir(p) {
			return filepath.Clean(path)
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
}

// grant is an entry to give write access to: a folder with all that is in it,
// or a file.
type grant struct {
	path string
	dir  bool
}

// plan lists what to grant so that everything stays writable but the protected
// folders: each folder and file beside the path from / down to a protected
// folder, and no folder on that path, whose entries then can't be made,
// removed or renamed. Symbolic links are left out: a write through one is
// checked where it lands.
func plan(protected []string) []grant {
	isProtected := make(map[string]bool, len(protected))
	onPath := make(map[string]bool)
	for _, p := range protected {
		isProtected[p] = true
		for d := filepath.Dir(p); !onPath[d]; d = filepath.Dir(d) {
			onPath[d] = true
		}
	}
	dirs := make([]string, 0, len(onPath))
	for d := range onPath {
		if !isProtected[d] {
			dirs = append(dirs, d)
		}
	}
	sort.Strings(dirs)
	var grants []grant
	for _, d := range dirs {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue // nothing in it is granted: it all stays unwritable
		}
		for _, e := range entries {
			p := filepath.Join(d, e.Name())
			if onPath[p] || isProtected[p] {
				continue
			}
			switch {
			case e.Type().IsDir():
				grants = append(grants, grant{path: p, dir: true})
			case e.Type().IsRegular():
				grants = append(grants, grant{path: p})
			}
		}
	}
	return grants
}

// shellPath is the shell Claude Code runs commands with, which the command it
// hands over is written for, picked as Claude Code picks it: $CLAUDE_CODE_SHELL,
// then $SHELL, when either is bash or zsh, then zsh or bash from PATH (bash
// first when $SHELL is bash).
func shellPath(override, login string) (string, error) {
	for _, s := range []string{override, login} {
		if strings.Contains(s, "bash") || strings.Contains(s, "zsh") {
			if p, err := exec.LookPath(s); err == nil {
				return p, nil
			}
		}
	}
	names := []string{"zsh", "bash"}
	if strings.Contains(login, "bash") {
		names = []string{"bash", "zsh"}
	}
	for _, n := range names {
		if p, err := exec.LookPath(n); err == nil {
			return p, nil
		}
	}
	return "", errors.New("found no bash or zsh to run the command with")
}
