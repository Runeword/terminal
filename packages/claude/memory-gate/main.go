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
//   - PreToolUse (Write, Edit, MultiEdit, NotebookEdit, Bash): a write to a
//     memory folder, or a shell command that names one, is denied while Claude
//     works, and the session is marked as holding a change. Once Claude has
//     been given the turn back, the same call is asked about instead, so the
//     user approves each change.
//   - Stop: a session holding a change is kept going (decision "block") to
//     make its changes again; the next stop ends the turn.
//   - UserPromptSubmit: a new prompt closes memory again.
//
// The state is one file per session in <config>/memory-gate/. An error (input
// it can't read, state it can't write) exits 1, which Claude Code treats as a
// non-blocking error: the call then goes through the normal permission check,
// where the ask rule still asks before a memory write.
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
	heldReason  = "Held: memory changes wait until your work is done, so that their permission prompt doesn't stop it. Carry on with the task; once you finish, you get the turn back to make this change again, and the user is asked then."
	shellReason = "Held: this command names a memory folder, which waits until your work is done. While you work, read memory with Read, Grep or Glob; once you finish, you get the turn back to make memory changes."
	stopReason  = "Your work is done, so memory is open: make again the memory changes that were held (Write or Edit; rm to delete a memory file). Each one asks the user. If none is still worth making, stop."
	askReason   = "Claude held this memory change until its work was done."
)

// sessionRE matches a session id, which names the session's state file.
var sessionRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// memoryRE finds a memory folder of a config directory named .claude* in a
// clean, lowercased, slash-separated path.
var memoryRE = regexp.MustCompile(`/\.claude[^/]*/projects/[^/]+/memory(/|$)`)

// shellProjectsRE finds the projects folder of a config directory in a shell
// command: ~/.claude-1/projects, ~/.claude*/projects, $CLAUDE_CONFIG_DIR/projects.
var shellProjectsRE = regexp.MustCompile(`(?i)(\.claude[^/\s'"]*|\$\{?CLAUDE_CONFIG_DIR\}?)/projects\b`)

type hookInput struct {
	SessionID     string `json:"session_id"`
	HookEventName string `json:"hook_event_name"`
	ToolName      string `json:"tool_name"`
	ToolInput     struct {
		FilePath     string `json:"file_path"`
		NotebookPath string `json:"notebook_path"`
		Command      string `json:"command"`
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
	if err := run(os.Stdin, os.Stdout, configDir()); err != nil {
		fmt.Fprintln(os.Stderr, "claude-memory-gate:", err)
		os.Exit(1)
	}
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
// config directory, which holds the memory folders and the state.
func run(in io.Reader, out io.Writer, config string) error {
	var input hookInput
	if err := json.NewDecoder(in).Decode(&input); err != nil {
		return fmt.Errorf("reading the hook's input: %w", err)
	}
	switch input.HookEventName {
	case "PreToolUse":
		return gate(input, out, config)
	case "Stop":
		return stop(input, out, config)
	case "UserPromptSubmit":
		return prompt(input, config)
	}
	return fmt.Errorf("unexpected hook event %q", input.HookEventName)
}

// gate denies a call that changes memory while Claude works, and asks about it
// once Claude has the turn back for memory. Any other call passes untouched.
func gate(input hookInput, out io.Writer, config string) error {
	reason := heldReason
	switch input.ToolName {
	case "Write", "Edit", "MultiEdit":
		if !inMemory(input.ToolInput.FilePath, config) {
			return nil
		}
	case "NotebookEdit":
		if !inMemory(input.ToolInput.NotebookPath, config) {
			return nil
		}
	case "Bash":
		if !namesMemory(input.ToolInput.Command, config) {
			return nil
		}
		reason = shellReason
	default:
		return nil
	}
	file, err := stateFile(input.SessionID, config)
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
	return decide(out, "deny", reason)
}

// stop gives the turn back to a session holding a memory change, and lets the
// turn end once it had it back.
func stop(input hookInput, out io.Writer, config string) error {
	file, err := stateFile(input.SessionID, config)
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
func prompt(input hookInput, config string) error {
	file, err := stateFile(input.SessionID, config)
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

// namesMemory reports whether a shell command names a memory folder: it names
// the projects folder of a config directory (~/.claude-1/projects,
// $CLAUDE_CONFIG_DIR/projects, or config's own path) and "mem" (memory, or a
// glob such as mem*). It goes by the command's text, so a command that builds
// the path at run time gets through.
func namesMemory(command, config string) bool {
	lower := strings.ToLower(command)
	if !strings.Contains(lower, "mem") {
		return false
	}
	if shellProjectsRE.MatchString(command) {
		return true
	}
	return strings.Contains(lower, strings.ToLower(filepath.ToSlash(filepath.Clean(config)))+"/projects")
}

// stateFile is the session's state file, in <config>/memory-gate.
func stateFile(session, config string) (string, error) {
	if !sessionRE.MatchString(session) {
		return "", fmt.Errorf("the hook's input names no session: %q", session)
	}
	return filepath.Join(config, "memory-gate", session), nil
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
