// Command claude-docs-guard is a Claude Code UserPromptSubmit hook that
// detects prompts about Claude / Anthropic tooling and injects a hard
// instruction to consult live official documentation before answering.
// Turns the model's probabilistic "should I look at docs" instinct into a
// deterministic harness-enforced rule.
//
// # Protocol
//
// Reads the hook event JSON on stdin, extracts the "prompt" field, and if it
// matches any of the patterns below, prints the guard message on stdout and
// exits 0. On no match (or any error), exits 0 silently. The hook is
// advisory, never blocking: a parse error or empty stdin must not erase the
// user's prompt.
//
// The plain-text stdout is surfaced by Claude Code as additionalContext on
// the next turn. The official protocol also accepts a JSON
// hookSpecificOutput.additionalContext envelope; either form works today
// and plain text matches the prior shell hook's behaviour exactly.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
)

// patternClusters groups the trigger patterns by intent. Joined with "|" and
// wrapped in a single case-insensitive regex at init. Each cluster can be
// edited independently without juggling alternation bars.
var patternClusters = []string{
	// Claude / Anthropic product names.
	`claude[ -]code`,
	`claude[ -]?api`,
	`anthropic[ -]?(?:api|sdk)`,
	`agent[ -]?sdk`,
	`claude_agent_sdk`,
	`@anthropic-ai/sdk`,

	// MCP, word-bounded so "mcpd" / "mcprotocol" don't trigger.
	`\bmcp\b`,

	// Hook event names. (?i) covers casing.
	`userpromptsubmit`,
	`posttooluse`,
	`pretooluse`,
	`sessionstart`,
	`subagentstop`,
	`stop[ -]?hook`,
	`slash[ -]?command`,

	// Claude-prefixed feature words.
	`claude[ -]?(?:hook|skill|subagent|plugin|command)`,
	`claude\.md`,

	// "claude … feature/release/changelog/version/doc" within 40 chars —
	// catches "the latest claude release", "claude version 4.7 changelog", etc.
	`claude.{0,40}(?:feature|release|changelog|version|doc)`,

	// Model family + version digit: "opus 4", "sonnet-4", "haiku 4".
	`\b(?:opus|sonnet|haiku)[ -]?[0-9]`,
}

var triggerPattern = regexp.MustCompile(`(?i)` + strings.Join(patternClusters, "|"))

const guardMessage = "[docs-guard] The user's question concerns Claude Code, the Claude Agent SDK, the Claude API, or Anthropic tooling.\n" +
	"\n" +
	"You MUST verify your answer against the live official documentation BEFORE responding from training data. Pick one:\n" +
	"\n" +
	"1. `claude-code-guide` subagent — best for multi-page / research-shaped questions; it synthesizes across pages and cites sources.\n" +
	"2. `WebFetch` directly against the canonical docs — best when you know the specific page:\n" +
	"   - Claude Code: https://docs.claude.com/en/docs/claude-code/\n" +
	"   - Claude API:  https://docs.claude.com/en/api/\n" +
	"   - MCP:         https://docs.claude.com/en/docs/mcp\n" +
	"   - Agent SDK:   https://docs.claude.com/en/api/agent-sdk/\n" +
	"\n" +
	"If, after attempting a lookup, you still answer from training data, state that explicitly so the user knows the answer may be stale."

type hookInput struct {
	Prompt string `json:"prompt"`
}

func main() {
	if shouldGuard(os.Stdin) {
		fmt.Println(guardMessage)
	}
}

// shouldGuard returns true when stdin parses and the prompt matches any
// trigger cluster. Any error path returns false: the hook is non-blocking
// and must not surface stderr noise on broken input.
func shouldGuard(r io.Reader) bool {
	prompt, err := readPrompt(r)
	if err != nil || prompt == "" {
		return false
	}
	return triggerPattern.MatchString(prompt)
}

func readPrompt(r io.Reader) (string, error) {
	var in hookInput
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return "", err
	}
	return in.Prompt, nil
}
