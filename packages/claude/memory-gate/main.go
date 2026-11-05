// Command claude-memory-gate holds Claude Code's memory changes until the
// work is done. Claude Code writes its auto memory
// (<config>/projects/<project>/memory/) whenever the model decides to, and the
// ask rule in settings.json turns each write into a permission prompt, which
// stops the task until the user answers. This hook refuses those writes while
// Claude works and gives the turn back once Claude stops, so the prompts come
// after the work instead of in the middle of it.
//
// # Protocol
//
// settings.json runs it, with no arguments, on three hook events, and it reads
// the event's JSON on stdin:
//
//   - PreToolUse (Write, Edit, MultiEdit, NotebookEdit): a write to a memory
//     folder is denied while Claude works, and the session is marked as holding
//     a change. Once Claude has been given the turn back, the same call is
//     asked about instead, so the user approves each change.
//   - Stop: a session holding a change is kept going (decision "block") to
//     make its changes again; the next stop ends the turn.
//   - UserPromptSubmit: a new prompt closes memory again.
//
// It only decides when the prompts come. Whether a change is made is settled
// elsewhere: the ask rule asks before each write by the file tools, and
// claude-shell-guard keeps shell commands from writing memory at all. So an
// error here (input it can't read, state it can't write), which exits 1 and
// which Claude Code treats as non-blocking, only brings a prompt forward.
//
// The state is one file per session in $XDG_RUNTIME_DIR/claude-memory-gate
// (else the temp folder), which claude-shell-guard, which runs hooks too,
// leaves writable.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// A session's state, the content of its file. No file: Claude is working and
// holds no change.
const (
	// holding: a memory change was denied while Claude worked.
	holding = "holding"
	// saving: Claude stopped while holding a change and was given the turn
	// back to make it again, asked about this time.
	saving = "saving"
)

// What Claude reads back from a denial and a block, and what the user's
// permission prompt says.
const (
	heldReason = "Held: memory changes wait until your work is done, so that their permission prompt doesn't stop it. Carry on with the task; once you finish, you get the turn back to make this change again, and the user is asked then."
	stopReason = "Your work is done, so memory is open: make again the memory changes that were held, with Write or Edit (the shell can't change memory; to delete a memory file, ask the user). Each one asks the user. If none is still worth making, stop."
	askReason  = "Claude held this memory change until its work was done."
)

// sessionRE matches a session id, which names the session's state file.
var sessionRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// memoryRE finds a memory folder of a config directory named .claude* in a
// clean, lowercased, slash-separated path.
var memoryRE = regexp.MustCompile(`/\.claude[^/]*/projects/[^/]+/memory(/|$)`)

type hookInput struct {
	SessionID     string `json:"session_id"`
	HookEventName string `json:"hook_event_name"`
	ToolName      string `json:"tool_name"`
	ToolInput     struct {
		FilePath     string `json:"file_path"`
		NotebookPath string `json:"notebook_path"`
	} `json:"tool_input"`
}

type toolDecision struct {
	HookSpecificOutput struct {
		HookEventName            string `json:"hookEventName"`
		PermissionDecision       string `json:"permissionDecision"`
		PermissionDecisionReason string `json:"permissionDecisionReason"`
	} `json:"hookSpecificOutput"`
}

type stopDecision struct {
	Decision string `json:"decision"`
	Reason   string `json:"reason"`
}

func main() {
	if err := run(os.Stdin, os.Stdout, configDir(), stateDir()); err != nil {
		fmt.Fprintln(os.Stderr, "claude-memory-gate:", err)
		os.Exit(1)
	}
}

// stateDir holds the sessions' state: $XDG_RUNTIME_DIR/claude-memory-gate,
// else the temp folder's.
func stateDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "claude-memory-gate")
	}
	return filepath.Join(os.TempDir(), "claude-memory-gate")
}

// configDir is Claude Code's config directory: $CLAUDE_CONFIG_DIR, else
// ~/.claude.
func configDir() string {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".claude"
	}
	return filepath.Join(home, ".claude")
}

// run answers the hook event read from in on out. config is Claude Code's
// config directory, which holds the memory folders, and states the folder of
// the sessions' state files.
func run(in io.Reader, out io.Writer, config, states string) error {
	var input hookInput
	if err := json.NewDecoder(in).Decode(&input); err != nil {
		return fmt.Errorf("reading the hook's input: %w", err)
	}
	switch input.HookEventName {
	case "PreToolUse":
		return gate(input, out, config, states)
	case "Stop":
		return stop(input, out, states)
	case "UserPromptSubmit":
		return prompt(input, states)
	}
	return fmt.Errorf("unexpected hook event %q", input.HookEventName)
}

// gate denies a write to memory while Claude works, and asks about it once
// Claude has the turn back for memory. Any other call passes untouched.
func gate(input hookInput, out io.Writer, config, states string) error {
	var path string
	switch input.ToolName {
	case "Write", "Edit", "MultiEdit":
		path = input.ToolInput.FilePath
	case "NotebookEdit":
		path = input.ToolInput.NotebookPath
	}
	if !inMemory(path, config) {
		return nil
	}
	file, err := stateFile(input.SessionID, states)
	if err != nil {
		return err
	}
	state, err := readState(file)
	if err != nil {
		return err
	}
	if state == saving {
		return decide(out, "ask", askReason)
	}
	if err := writeState(file, holding); err != nil {
		return err
	}
	return decide(out, "deny", heldReason)
}

// stop gives the turn back to a session holding a memory change, and lets the
// turn end once it had it back.
func stop(input hookInput, out io.Writer, states string) error {
	file, err := stateFile(input.SessionID, states)
	if err != nil {
		return err
	}
	state, err := readState(file)
	if err != nil {
		return err
	}
	switch state {
	case holding:
		if err := writeState(file, saving); err != nil {
			return err
		}
		return json.NewEncoder(out).Encode(stopDecision{Decision: "block", Reason: stopReason})
	case saving:
		return clearState(file)
	}
	return nil
}

// prompt closes memory again when the user writes, which ends a turn given
// back for memory even when an interruption kept Claude from stopping. A
// change still held waits for the end of the new turn.
func prompt(input hookInput, states string) error {
	file, err := stateFile(input.SessionID, states)
	if err != nil {
		return err
	}
	state, err := readState(file)
	if err != nil {
		return err
	}
	if state == saving {
		return clearState(file)
	}
	return nil
}

// inMemory reports whether path is in a memory folder,
// <config>/projects/<project>/memory: under config, or under any directory
// named .claude* (every profile: ~/.claude, ~/.claude-1, …), as the ask rule in
// settings.json matches it. Case is ignored, which on a case-sensitive file
// system only widens the match.
func inMemory(path, config string) bool {
	if path == "" {
		return false
	}
	p := strings.ToLower(filepath.ToSlash(filepath.Clean(path)))
	if memoryRE.MatchString(p) {
		return true
	}
	root := strings.ToLower(filepath.ToSlash(filepath.Clean(config))) + "/projects/"
	rest, ok := strings.CutPrefix(p, root)
	if !ok {
		return false
	}
	_, inProject, ok := strings.Cut(rest, "/")
	return ok && (inProject == "memory" || strings.HasPrefix(inProject, "memory/"))
}

// stateFile is the session's state file, in states.
func stateFile(session, states string) (string, error) {
	if !sessionRE.MatchString(session) {
		return "", fmt.Errorf("the hook's input names no session: %q", session)
	}
	return filepath.Join(states, session), nil
}

func readState(file string) (string, error) {
	b, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

func writeState(file, state string) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return err
	}
	return os.WriteFile(file, []byte(state+"\n"), 0o600)
}

func clearState(file string) error {
	err := os.Remove(file)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}

// decide prints a PreToolUse permission decision.
func decide(out io.Writer, decision, reason string) error {
	var d toolDecision
	d.HookSpecificOutput.HookEventName = "PreToolUse"
	d.HookSpecificOutput.PermissionDecision = decision
	d.HookSpecificOutput.PermissionDecisionReason = reason
	return json.NewEncoder(out).Encode(d)
}
