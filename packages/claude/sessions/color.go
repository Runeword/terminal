package main

// color picks the color a new session starts with. __claude
// (sources/.config/shell/functions/claude.bash) hands it to Claude Code's
// /color as the session's first prompt, which colors the session's prompt bar
// and records the color in its transcript, as an agent-color record that a
// resumed session gets its color back from. The color is the first of palette
// that no open session holds, so the sessions open side by side tell apart,
// else the first of those the fewest hold. The open sessions are those a held
// lock names (openByLock): __claude starts every session but the microVM's
// under one, and the locks answer at once, where looking for the claudes can
// take seconds.

import (
	"bytes"
	"encoding/json"
	"slices"
)

// palette is the colors /color takes, in the order color hands them out: the
// first ones far apart in hue, and red, which reads as a warning, last.
var palette = []string{"blue", "green", "purple", "orange", "cyan", "pink", "yellow", "red"}

// newColor is the color for a new session, open being the sessions open now,
// each with the profile it runs in.
func newColor(open map[string]string) string {
	held := make(map[string]int, len(palette))
	for id, config := range open {
		if c := sessionColor(config, id); c != "" {
			held[c]++
		}
	}
	pick := palette[0]
	for _, c := range palette[1:] {
		if held[c] < held[pick] {
			pick = c
		}
	}
	return pick
}

// sessionColor is the color session id of profile config holds, as its
// transcript last records it: "" for none, and for a name /color doesn't take,
// such as the default it records when its color is reset. It reads only both
// ends of the transcript, as list does, the end first: a record there is the
// later one.
func sessionColor(config, id string) string {
	paths, err := transcripts(config, id)
	if err != nil {
		return ""
	}
	l, err := readLite(paths[0])
	if err != nil {
		return ""
	}
	c := recordedColor(l.tail)
	if c == "" {
		c = recordedColor(l.head)
	}
	if !slices.Contains(palette, c) {
		return ""
	}
	return c
}

// recordedColor is the color the last whole agent-color record in b holds, ""
// when b holds none. The lines cut at either end of a lite read don't parse,
// so they don't count.
func recordedColor(b []byte) string {
	lines := bytes.Split(b, []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		if !bytes.Contains(lines[i], []byte(`"agent-color"`)) {
			continue
		}
		var r struct {
			Type       string `json:"type"`
			AgentColor string `json:"agentColor"`
		}
		if json.Unmarshal(lines[i], &r) == nil && r.Type == "agent-color" {
			return r.AgentColor
		}
	}
	return ""
}
