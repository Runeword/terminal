package main

import (
	"bytes"
	"encoding/json"
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

func TestNamesMemory(t *testing.T) {
	tests := []struct {
		name    string
		command string
		want    bool
	}{
		{"cat a memory file", "cat ~/.claude-1/projects/-home-u-repo/memory/MEMORY.md", true},
		{"rm through the variable", `rm "$CLAUDE_CONFIG_DIR/projects/-home-u-repo/memory/x.md"`, true},
		{"cd, then a relative path", "cd ~/.claude-1/projects/-home-u-repo && rm memory/x.md", true},
		{"a glob", "ls ~/.claude*/projects/*/mem*", true},
		{"the config dir's own path", "cat /srv/cfg/projects/p/memory/x.md", true},
		{"transcripts", "rg -l foo ~/.claude-1/projects/-home-u-repo/*.jsonl", false},
		{"a repo's memory folder", "ls ./memory", false},
		{"a path built at run time gets through", "d=~/.claude-1; rm $d/projects/p/memory/x.md", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := namesMemory(tt.command, "/srv/cfg"); got != tt.want {
				t.Errorf("namesMemory(%q) = %v, want %v", tt.command, got, tt.want)
			}
		})
	}
}

// TestTurns plays turns through the hook, in order: each step's state is the
// next step's start.
func TestTurns(t *testing.T) {
	config := t.TempDir()
	memory := filepath.Join(config, "projects", "-home-u-repo", "memory")
	steps := []struct {
		name  string
		input hookInput
		want  string // the decision printed, "" for none
		state string // the session's state after it
	}{
		{"a write elsewhere passes", tool("Write", "/home/u/repo/main.go", ""), "", ""},
		{"a memory write is held", tool("Write", filepath.Join(memory, "user_role.md"), ""), "deny", holding},
		{"so is an edit of the index", tool("Edit", filepath.Join(memory, "MEMORY.md"), ""), "deny", holding},
		{"stopping gives the turn back", event("Stop"), "block", saving},
		{"the write is asked about now", tool("Write", filepath.Join(memory, "user_role.md"), ""), "ask", saving},
		{"so is a shell command", tool("Bash", "", "rm "+filepath.Join(memory, "old.md")), "ask", saving},
		{"the next stop ends the turn", event("Stop"), "", ""},
		{"a stop with nothing held ends the turn", event("Stop"), "", ""},
		{"a shell command naming memory is held", tool("Bash", "", "cat "+filepath.Join(memory, "MEMORY.md")), "deny", holding},
		{"a notebook in memory is held", tool("NotebookEdit", filepath.Join(memory, "n.ipynb"), ""), "deny", holding},
		{"a new prompt keeps what is held", event("UserPromptSubmit"), "", holding},
		{"stopping gives the turn back again", event("Stop"), "block", saving},
		{"a new prompt closes memory", event("UserPromptSubmit"), "", ""},
		{"a memory write is held again", tool("Edit", filepath.Join(memory, "MEMORY.md"), ""), "deny", holding},
	}
	for _, step := range steps {
		t.Run(step.name, func(t *testing.T) {
			in, err := json.Marshal(step.input)
			if err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			if err := run(bytes.NewReader(in), &out, config); err != nil {
				t.Fatalf("run: %v", err)
			}
			if got := decision(t, out.Bytes()); got != step.want {
				t.Errorf("decision = %q, want %q (output %q)", got, step.want, out.String())
			}
			if got := state(t, config); got != step.state {
				t.Errorf("state = %q, want %q", got, step.state)
			}
		})
	}
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
			if err := run(strings.NewReader(tt.input), &out, t.TempDir()); err == nil {
				t.Errorf("run succeeded, printing %q", out.String())
			}
		})
	}
}

func tool(name, path, command string) hookInput {
	in := event("PreToolUse")
	in.ToolName = name
	in.ToolInput.FilePath = path
	if name == "NotebookEdit" {
		in.ToolInput.FilePath, in.ToolInput.NotebookPath = "", path
	}
	in.ToolInput.Command = command
	return in
}

func event(name string) hookInput {
	return hookInput{SessionID: session, HookEventName: name}
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

func state(t *testing.T, config string) string {
	t.Helper()
	got, err := readState(filepath.Join(config, "memory-gate", session))
	if err != nil {
		t.Fatal(err)
	}
	return got
}
