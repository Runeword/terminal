package main

import (
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

// Unit Separator: a delimiter that cannot occur in a session name or a path,
// unlike the spaces and tabs a naive format string would split on.
const sep = "\x1f"

type session struct {
	name         string
	windows      string
	path         string
	attached     bool
	lastAttached int64
}

// tmuxBin resolves the tmux to drive. A popup inherits the tmux server's
// environment, whose PATH is whatever launched the server and need not contain
// tmux at all, so the wrapper hands us an absolute path; falling back to PATH
// keeps the command usable when run by hand from a shell.
func tmuxBin() string {
	if p := os.Getenv("TMUX_SESSIONS_TMUX"); p != "" {
		return p
	}
	return "tmux"
}

func tmux(args ...string) (string, error) {
	out, err := exec.Command(tmuxBin(), args...).Output()
	return strings.TrimRight(string(out), "\n"), err
}

// listSessions returns every session most-recently-used first.
//
// That ordering is what makes Alt+Tab feel like a window switcher: index 0 is
// the session you are in, index 1 the one you were in before it, so a single
// Alt+Tab lands on "the other one".
func listSessions() ([]session, error) {
	format := strings.Join([]string{
		"#{session_last_attached}",
		"#{session_name}",
		"#{session_windows}",
		"#{session_attached}",
		"#{session_path}",
	}, sep)

	out, err := tmux("list-sessions", "-F", format)
	if err != nil {
		return nil, err
	}
	if out == "" {
		return nil, nil
	}

	var sessions []session
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, sep)
		if len(f) < 5 {
			continue
		}
		last, _ := strconv.ParseInt(f[0], 10, 64)
		sessions = append(sessions, session{
			lastAttached: last,
			name:         f[1],
			windows:      f[2],
			attached:     f[3] != "0",
			path:         f[4],
		})
	}

	sort.SliceStable(sessions, func(i, j int) bool {
		return sessions[i].lastAttached > sessions[j].lastAttached
	})
	return sessions, nil
}

func currentSession() string {
	name, err := tmux("display-message", "-p", "#{session_name}")
	if err != nil {
		return ""
	}
	return name
}

// switchTo moves the calling client to name. The leading '=' forces an exact
// match, so a session named "web" is never resolved to "web-api".
func switchTo(name string) error {
	_, err := tmux("switch-client", "-t", "="+name)
	return err
}

func insideTmux() bool {
	return os.Getenv("TMUX") != ""
}

// homePath abbreviates $HOME to ~ so the path column stays narrow enough to
// sit beside the session name in a popup.
func homePath(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || p == "" {
		return p
	}
	if p == home {
		return "~"
	}
	if strings.HasPrefix(p, home+"/") {
		return "~" + p[len(home):]
	}
	return p
}
