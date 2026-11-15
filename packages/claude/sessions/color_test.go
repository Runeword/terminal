package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// colorSet is the record /color writes when it sets a session's color.
func colorSet(color string) string {
	return `{"type":"agent-color","agentColor":"` + color + `"}`
}

// colorSession is session id's transcript in profile config, holding lines.
func colorSession(t *testing.T, config, id string, lines ...string) {
	t.Helper()
	write(t, filepath.Join(config, "projects", "-p", id+".jsonl"), lines...)
}

func TestNewColor(t *testing.T) {
	prompt := `{"type":"user","message":{"content":"hi"}}`
	// Two of these push what follows past the head a lite read takes.
	long := `{"type":"user","message":{"content":"` + strings.Repeat("x", liteBuf) + `"}}`
	var once, twice [][]string
	for _, c := range palette {
		once = append(once, []string{colorSet(c)})
	}
	twice = append(append(twice, once...), []string{colorSet("blue")}, []string{colorSet("green")})
	tests := []struct {
		name     string
		sessions [][]string // each open session's transcript
		want     string
	}{
		{name: "no session open", want: "blue"},
		{name: "an open session with no color", sessions: [][]string{{prompt}}, want: "blue"},
		{name: "the first colors held", sessions: [][]string{{colorSet("blue"), prompt}, {colorSet("green"), prompt}}, want: "purple"},
		{name: "a color between two held", sessions: [][]string{{colorSet("blue")}, {colorSet("purple")}}, want: "green"},
		{name: "the last /color counts", sessions: [][]string{{colorSet("blue"), prompt, colorSet("green")}}, want: "blue"},
		{name: "a color reset", sessions: [][]string{{colorSet("blue"), colorSet("default")}}, want: "blue"},
		{name: "names /color doesn't take", sessions: [][]string{{colorSet("$(touch x)")}, {colorSet("Blue")}}, want: "blue"},
		{name: "a record quoted in a prompt", sessions: [][]string{{`{"type":"user","message":{"content":"{\"type\":\"agent-color\",\"agentColor\":\"blue\"}"}}`}}, want: "blue"},
		{name: "the end's record, past the head", sessions: [][]string{{colorSet("blue"), long, long, colorSet("red")}}, want: "blue"},
		{name: "the head's record, none at the end", sessions: [][]string{{colorSet("blue"), long, long}}, want: "green"},
		{name: "every color held once", sessions: once, want: "blue"},
		{name: "the first the fewest hold", sessions: twice, want: "purple"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			home := t.TempDir()
			open := map[string]string{}
			for i, lines := range tt.sessions {
				// Sessions of two profiles count alike.
				config := filepath.Join(home, fmt.Sprintf(".claude-%d", i%2+1))
				id := fmt.Sprintf("%08x-0000-4000-8000-%012x", i, i)
				colorSession(t, config, id, lines...)
				open[id] = config
			}
			if got := newColor(open); got != tt.want {
				t.Errorf("newColor = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestNewColorOfTheSessionsALockNames(t *testing.T) {
	home := t.TempDir()
	now := time.Now()
	one := filepath.Join(home, ".claude-1")
	colorSession(t, one, idA, colorSet("blue"))
	colorSession(t, one, idB, colorSet("green"))
	colorSession(t, one, idC, colorSet("purple"))
	launchFile(t, one, "open", idA, true)
	ended := launchFile(t, one, "ended", idB, false)
	if err := os.Chtimes(ended, now.Add(-2*staleAfter), now.Add(-2*staleAfter)); err != nil {
		t.Fatal(err)
	}
	// Session C has no launch file: a claude __claude did not start.
	if got, want := newColor(openByLock(home, now)), "green"; got != want {
		t.Errorf("newColor = %q, want %q: only session A is open", got, want)
	}
}
