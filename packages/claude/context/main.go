// Command claude-context gives independently launched Claude Code sessions a
// shared, append-only journal, so several sessions can work from the same
// understanding without any of them being a "lead".
//
// Membership is explicit. A session joins the group named by
// $CLAUDE_CONTEXT_GROUP, and every subcommand no-ops silently when that is
// unset — an ungrouped session is completely untouched.
//
//	claude-context hook session-start   catch-up digest + publishing protocol
//	claude-context hook prompt          entries added since this session last read
//	claude-context hook post-tool       record an Edit/Write as an `edit` entry
//	claude-context hook session-end     record departure, drop per-session state
//	claude-context note <text>          publish deliberately (run by the model)
//	claude-context log [group] [-f]     human view of the journal
//	claude-context peers [group]        sessions currently in the group
//
// # Why hooks rather than an MCP server
//
// Delivery is push, not pull. Claude Code injects SessionStart and
// UserPromptSubmit stdout into the model's context, so a peer's finding arrives
// whether or not the model thinks to look for it. A memory MCP server would be
// less code but only ever answers when queried. Reads are incremental: each
// session keeps a byte cursor into the journal, so a prompt with no peer
// activity emits nothing and costs zero context.
//
// # Where state lives
//
// $CLAUDE_CONFIG_DIR/shared/<group>/. That is the one durable location
// writable from inside the bubblewrap sandbox (claude-sandbox.bash binds
// $CLAUDE_CONFIG_DIR read-write) and shared by every session launched with the
// same instance number. Deliberately not $XDG_RUNTIME_DIR, which the sandbox
// replaces with a private tmpfs — state written there is invisible to peers.
//
// Every hook path exits 0 whatever happens. A hook that fails must never block
// a session, and stderr noise on a broken payload would be worse than silence.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// hookInput is the subset of the hook payload this tool reads.
//
// Prompt and UserInput are both present because the field carrying the user's
// text has been named both ways across versions; neither is required here
// (the prompt body is not used), but decoding both keeps the struct honest
// about what arrives.
type hookInput struct {
	HookEventName string `json:"hook_event_name"`
	SessionID     string `json:"session_id"`
	Cwd           string `json:"cwd"`
	Source        string `json:"source"` // SessionStart: startup|resume|clear|compact|fork
	Prompt        string `json:"prompt"`
	UserInput     string `json:"user_input"`
	ToolName      string `json:"tool_name"`
	ToolInput     struct {
		FilePath string `json:"file_path"`
	} `json:"tool_input"`
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "hook":
		if len(os.Args) < 3 {
			usage()
		}
		runHook(os.Args[2])
	case "note":
		runNote(strings.Join(os.Args[2:], " "))
	case "log":
		runLog(os.Args[2:])
	case "peers":
		runPeers(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  claude-context note <text>           publish to this session's group
  claude-context log [group] [-f]      read the journal (-f to follow)
  claude-context peers [group]         sessions currently in the group
  claude-context hook <event>          internal; wired from settings.json

The group defaults to $CLAUDE_CONTEXT_GROUP, which is set inside a grouped
session but not in an interactive shell — pass it explicitly there. State is
read from $CLAUDE_CONFIG_DIR, defaulting to ~/.claude-1.`)
	os.Exit(2)
}

// ---------------------------------------------------------------------- hooks

// runHook always exits 0. Claude Code treats a non-zero hook as an error the
// user sees, and nothing this tool does is worth interrupting a session for.
func runHook(event string) {
	var in hookInput
	_ = json.NewDecoder(os.Stdin).Decode(&in) // best-effort; ignore parse errors

	s := open()
	if s == nil || in.SessionID == "" {
		return // not in a group, or no session to attribute: stay silent
	}

	self := in.SessionID
	me := peer{Session: self, Label: labelFor(in.Cwd, self), Cwd: in.Cwd}

	switch event {
	case "session-start":
		s.touch(me)
		// Only a genuine startup is a join. resume/clear/compact/fork re-fire
		// this hook for the same session, and announcing a rejoin each time a
		// context compacts would be noise in every peer's digest.
		if in.Source == "" || in.Source == "startup" {
			_ = s.append(entry{TS: now(), Session: self, Label: me.Label, Kind: "join"})
		}
		// Read from the top: a fresh session has seen nothing, and a compacted
		// one has just lost what it saw. digest caps the volume either way.
		es, next, err := s.readSince(0)
		if err != nil {
			return
		}
		s.setCursor(self, next)
		out := protocol(s.group, s.peers(self, time.Now()))
		if d := digest(s.group, self, es); d != "" {
			out += "\n" + d
		}
		fmt.Print(out)

	case "prompt":
		s.touch(me)
		es, next, err := s.readSince(s.cursor(self))
		if err != nil {
			return
		}
		s.setCursor(self, next)
		if d := digest(s.group, self, es); d != "" {
			fmt.Print(d)
		}

	case "post-tool":
		if in.ToolInput.FilePath == "" {
			return
		}
		s.touch(me)
		_ = s.append(entry{
			TS:      now(),
			Session: self,
			Label:   me.Label,
			Kind:    "edit",
			Path:    relPath(in.Cwd, in.ToolInput.FilePath),
		})

	case "session-end":
		_ = s.append(entry{TS: now(), Session: self, Label: me.Label, Kind: "leave"})
		s.drop(self)
	}
}

// ---------------------------------------------------------------- subcommands

// runNote publishes a deliberate entry. Unlike the hooks it reports failure:
// the model ran this on purpose and should learn if nothing was written.
func runNote(text string) {
	text = strings.TrimSpace(clean(text))
	if text == "" {
		fail("note text is empty")
	}
	s := open()
	if s == nil {
		fail("this session is not in a shared-context group (CLAUDE_CONTEXT_GROUP is unset)")
	}

	// The session id is exported to every Bash tool call, so a note attributes
	// itself without any process-tree climbing — and, more importantly, gets
	// filtered out of its own author's digest.
	self := os.Getenv("CLAUDE_CODE_SESSION_ID")

	// Prefer the label the hooks recorded: they see the session's real cwd,
	// while this process sees wherever the model last cd'd to.
	label := ""
	if p, ok := s.selfPeer(self); ok {
		label = p.Label
	}
	if label == "" {
		cwd, _ := os.Getwd()
		label = labelFor(cwd, self)
	}

	err := s.append(entry{
		TS:      now(),
		Session: self,
		Label:   label,
		Kind:    "note",
		Text:    text,
	})
	if err != nil {
		fail(err.Error())
	}
	fmt.Printf("published to shared-context group %q\n", s.group)
}

// storeFor resolves the group for a human-facing command. An explicit
// positional argument wins, so these work from an interactive shell — which,
// unlike a session, has no CLAUDE_CONTEXT_GROUP to inherit.
func storeFor(args []string) *store {
	group := os.Getenv("CLAUDE_CONTEXT_GROUP")
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			group = a
			break
		}
	}
	s := openAt(configDir(), group)
	if s == nil {
		fail("no shared-context group: pass one (claude-context log <group>) or set CLAUDE_CONTEXT_GROUP")
	}
	return s
}

func runLog(args []string) {
	follow := false
	for _, a := range args {
		if a == "--follow" || a == "-f" {
			follow = true
		}
	}
	s := storeFor(args)

	var off int64
	for {
		es, next, err := s.readSince(off)
		if err != nil {
			fail(err.Error())
		}
		off = next
		for _, e := range es {
			fmt.Println(logLine(e))
		}
		if !follow {
			return
		}
		time.Sleep(time.Second)
	}
}

func logLine(e entry) string {
	body := clean(e.Text)
	if e.Kind == "edit" {
		body = "edited " + clean(e.Path)
	}
	if body == "" {
		body = e.Kind
	}
	return fmt.Sprintf("%s  %-18s %s",
		time.Unix(e.TS, 0).Format("15:04:05"), clean(e.Label), body)
}

func runPeers(args []string) {
	s := storeFor(args)
	ps := s.peers(os.Getenv("CLAUDE_CODE_SESSION_ID"), time.Now())
	if len(ps) == 0 {
		fmt.Println("no other sessions in the group")
		return
	}
	for _, p := range ps {
		fmt.Printf("%-18s %s\n", clean(p.Label), clean(homePath(p.Cwd)))
	}
}

// ---------------------------------------------------------------------- util

// labelFor names a session in its peers' digests. $CLAUDE_CONTEXT_LABEL wins;
// otherwise the project directory plus a short id, which stays unambiguous
// when two sessions sit in the same repo.
func labelFor(cwd, id string) string {
	if l := strings.TrimSpace(clean(os.Getenv("CLAUDE_CONTEXT_LABEL"))); l != "" {
		return l
	}
	base := baseName(cwd)
	short := id
	if len(short) > 4 {
		short = short[:4]
	}
	if short == "" {
		return base
	}
	return base + "/" + short
}

func baseName(cwd string) string {
	parts := strings.Split(strings.TrimRight(cwd, "/"), "/")
	b := parts[len(parts)-1]
	if b == "" || b == "." {
		return "session"
	}
	return clean(b)
}

func now() int64 { return time.Now().Unix() }

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "claude-context:", msg)
	os.Exit(1)
}
