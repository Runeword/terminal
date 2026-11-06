package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

const session = "3f2c8a9e-7b41-4d6a-9c05-1e8f6b2d4a73"

func TestInMemory(t *testing.T) {
	tests := []struct {
		name   string
		path   string
		config string
		want   bool
	}{
		{"a memory file", "/home/u/.claude-1/projects/-home-u-repo/memory/user_role.md", "/home/u/.claude-1", true},
		{"the memory index", "/home/u/.claude-1/projects/-home-u-repo/memory/MEMORY.md", "/home/u/.claude-1", true},
		{"another profile's", "/home/u/.claude/projects/-home-u-repo/memory/x.md", "/home/u/.claude-1", true},
		{"under a config dir named otherwise", "/srv/cfg/projects/-repo/memory/x.md", "/srv/cfg", true},
		{"a transcript", "/home/u/.claude-1/projects/-home-u-repo/0b1c.jsonl", "/home/u/.claude-1", false},
		{"a repo's memory folder", "/home/u/repo/memory/x.md", "/home/u/.claude-1", false},
		{"out of it through ..", "/home/u/.claude-1/projects/-home-u-repo/memory/../x.md", "/home/u/.claude-1", false},
		{"into it through ..", "/home/u/repo/../.claude-1/projects/p/memory/x.md", "/home/u/.claude-1", true},
		{"no path", "", "/home/u/.claude-1", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := inMemory(tt.path, tt.config); got != tt.want {
				t.Errorf("inMemory(%q, %q) = %v, want %v", tt.path, tt.config, got, tt.want)
			}
		})
	}
}

// step is one hook event of a test's turns.
type step struct {
	name  string
	input hookInput
	want  string // the decision printed, "" for none
	state string // the session's state after it
}

// TestTurns plays turns through the hook, in order: each step's state is the
// next step's start. It plays them through one copy of the hooks, then two, as
// when settings.json and the plugin both run them: each copy must decide as a
// lone copy does.
func TestTurns(t *testing.T) {
	config := t.TempDir()
	memory := filepath.Join(config, "projects", "-home-u-repo", "memory")
	steps := []step{
		{"a write elsewhere passes", tool("Write", "/home/u/repo/main.go"), "", ""},
		{"a memory write is held", tool("Write", filepath.Join(memory, "user_role.md")), "deny", holding},
		{"so is an edit of the index", tool("Edit", filepath.Join(memory, "MEMORY.md")), "deny", holding},
		{"stopping gives the turn back", event("Stop"), "block", saving},
		{"the write is asked about now", tool("Write", filepath.Join(memory, "user_role.md")), "ask", saving},
		{"a shell command passes: claude-shell-guard keeps the shell out", bash(), "", saving},
		{"the next stop ends the turn", stopAfterBlock(), "", ""},
		{"a stop with nothing held ends the turn", event("Stop"), "", ""},
		{"a notebook in memory is held", tool("NotebookEdit", filepath.Join(memory, "n.ipynb")), "deny", holding},
		{"a new prompt keeps what is held", event("UserPromptSubmit"), "", holding},
		{"stopping gives the turn back again", event("Stop"), "block", saving},
		{"a new prompt closes memory", event("UserPromptSubmit"), "", ""},
		{"a memory write is held again", tool("Edit", filepath.Join(memory, "MEMORY.md")), "deny", holding},
	}
	for _, copies := range []int{1, 2} {
		t.Run(fmt.Sprintf("%d copies", copies), func(t *testing.T) {
			play(t, steps, config, copies)
		})
	}
}

// TestAnotherStopHook: a change held while another Stop hook keeps Claude
// going is given back at the next stop, though Claude Code flags it as
// following a block, and the stop after that ends the turn. Through one copy
// of the hooks only: two disagree on that stop (see stop).
func TestAnotherStopHook(t *testing.T) {
	config := t.TempDir()
	memory := filepath.Join(config, "projects", "-home-u-repo", "memory", "x.md")
	play(t, []step{
		{"a memory write is held", tool("Write", memory), "deny", holding},
		{"the next stop gives the turn back", stopAfterBlock(), "block", saving},
		{"the write is asked about now", tool("Write", memory), "ask", saving},
		{"the stop after that ends the turn", stopAfterBlock(), "", ""},
	}, config, 1)
}

func TestErrors(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{"not JSON", "{"},
		{"no session", `{"hook_event_name":"Stop"}`},
		{"a session id that is a path", `{"hook_event_name":"Stop","session_id":"../x"}`},
		{"a memory write with no session", `{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/home/u/.claude/projects/p/memory/x.md"}}`},
		{"an event it isn't run on", `{"hook_event_name":"PostToolUse","session_id":"` + session + `"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := run(strings.NewReader(tt.input), &out, t.TempDir(), t.TempDir()); err == nil {
				t.Errorf("run succeeded, printing %q", out.String())
			}
		})
	}
}

func tool(name, path string) hookInput {
	in := event("PreToolUse")
	in.ToolName = name
	if name == "NotebookEdit" {
		in.ToolInput.NotebookPath = path
	} else {
		in.ToolInput.FilePath = path
	}
	return in
}

func bash() hookInput {
	in := event("PreToolUse")
	in.ToolName = "Bash"
	return in
}

func event(name string) hookInput {
	return hookInput{SessionID: session, HookEventName: name}
}

// stopAfterBlock is a stop that Claude Code flags as following a block.
func stopAfterBlock() hookInput {
	in := event("Stop")
	in.StopHookActive = true
	return in
}

// play runs steps in order, each through the given number of copies of the
// hook, one after the other, and checks each copy's decision and the session's
// state after it.
func play(t *testing.T, steps []step, config string, copies int) {
	t.Helper()
	states := t.TempDir()
	for _, s := range steps {
		t.Run(s.name, func(t *testing.T) {
			in, err := json.Marshal(s.input)
			if err != nil {
				t.Fatal(err)
			}
			for n := 1; n <= copies; n++ {
				var out bytes.Buffer
				if err := run(bytes.NewReader(in), &out, config, states); err != nil {
					t.Fatalf("copy %d: run: %v", n, err)
				}
				if got := decision(t, out.Bytes()); got != s.want {
					t.Errorf("copy %d: decision = %q, want %q (output %q)", n, got, s.want, out.String())
				}
				if got := state(t, states); got != s.state {
					t.Errorf("copy %d: state = %q, want %q", n, got, s.state)
				}
			}
		})
	}
}

// decision is the permission decision or the stop decision printed, "" for
// none.
func decision(t *testing.T, out []byte) string {
	t.Helper()
	if len(out) == 0 {
		return ""
	}
	var d struct {
		HookSpecificOutput struct {
			PermissionDecision string `json:"permissionDecision"`
		} `json:"hookSpecificOutput"`
		Decision string `json:"decision"`
	}
	if err := json.Unmarshal(out, &d); err != nil {
		t.Fatalf("output %q: %v", out, err)
	}
	if d.HookSpecificOutput.PermissionDecision != "" {
		return d.HookSpecificOutput.PermissionDecision
	}
	return d.Decision
}

func state(t *testing.T, states string) string {
	t.Helper()
	got, err := readState(filepath.Join(states, session))
	if err != nil {
		t.Fatal(err)
	}
	return got
}
