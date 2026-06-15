package main

import (
	"strings"
	"testing"
)

func TestShouldGuard(t *testing.T) {
	tests := []struct {
		name string
		body string
		want bool
	}{
		// Empty / malformed → false (advisory, fail open).
		{"empty stdin", "", false},
		{"empty prompt field", `{"prompt":""}`, false},
		{"missing prompt field", `{"hook_event_name":"UserPromptSubmit"}`, false},
		{"malformed json", `{not json`, false},

		// Plain prompts that should NOT trigger.
		{"unrelated question", `{"prompt":"how do I cd to git root"}`, false},
		{"go code question", `{"prompt":"explain this Go function"}`, false},
		{"mention of clouds", `{"prompt":"compare aws and gcp"}`, false},
		{"word containing mcp substr", `{"prompt":"what is mcprotocol"}`, false},
		{"haiku poem", `{"prompt":"write a haiku about autumn"}`, false},
		{"opus the music", `{"prompt":"what is an opus number in music"}`, false},
		{"claudecode no separator", `{"prompt":"claudecode is not a thing"}`, false},

		// Product names.
		{"claude code", `{"prompt":"how does claude code handle hooks"}`, true},
		{"claude-code dash", `{"prompt":"claude-code config"}`, true},
		{"Claude Code titlecase", `{"prompt":"Claude Code question"}`, true},
		{"claude api space", `{"prompt":"claude api pricing"}`, true},
		{"claudeapi nospace", `{"prompt":"claudeapi key rotation"}`, true},
		{"anthropic sdk", `{"prompt":"anthropic sdk migration"}`, true},
		{"anthropic-api", `{"prompt":"anthropic-api error 429"}`, true},
		{"agent sdk", `{"prompt":"agent sdk tool use"}`, true},
		{"agentsdk", `{"prompt":"agentsdk install"}`, true},
		{"claude_agent_sdk import", `{"prompt":"import claude_agent_sdk in python"}`, true},
		{"npm package", `{"prompt":"@anthropic-ai/sdk version"}`, true},

		// MCP, word-bounded.
		{"mcp lowercase", `{"prompt":"what is mcp"}`, true},
		{"MCP upper", `{"prompt":"MCP server setup"}`, true},

		// Hook event names.
		{"UserPromptSubmit", `{"prompt":"how does UserPromptSubmit work"}`, true},
		{"PreToolUse", `{"prompt":"PreToolUse exit codes"}`, true},
		{"PostToolUse", `{"prompt":"PostToolUse hook"}`, true},
		{"SessionStart", `{"prompt":"SessionStart hook"}`, true},
		{"SubagentStop", `{"prompt":"SubagentStop trigger"}`, true},
		{"stop hook", `{"prompt":"stop hook example"}`, true},
		{"slash command", `{"prompt":"how to write a slash command"}`, true},

		// Claude-prefixed features.
		{"claude skill", `{"prompt":"writing a claude skill"}`, true},
		{"claude-plugin", `{"prompt":"install a claude-plugin"}`, true},
		{"claude subagent", `{"prompt":"claude subagent config"}`, true},
		{"CLAUDE.md", `{"prompt":"what goes in CLAUDE.md"}`, true},

		// Proximity match.
		{"claude latest release", `{"prompt":"what's in the latest claude release"}`, true},
		{"claude version changelog", `{"prompt":"claude 4.7 version changelog"}`, true},
		{"claude unrelated far", `{"prompt":"claude likes cats and the weather is nice but the release is far"}`, false},

		// Model families with version digit.
		{"opus 4", `{"prompt":"is opus 4 available"}`, true},
		{"sonnet-4", `{"prompt":"sonnet-4 context window"}`, true},
		{"haiku 4", `{"prompt":"haiku 4 pricing"}`, true},
		{"opus no digit", `{"prompt":"compare opus and sonnet"}`, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shouldGuard(strings.NewReader(tt.body))
			if got != tt.want {
				t.Errorf("shouldGuard(%q) = %v, want %v", tt.body, got, tt.want)
			}
		})
	}
}

func TestGuardMessageShape(t *testing.T) {
	// Spot-check the surfaces the model is told to use; if any of these are
	// removed the guard becomes useless.
	for _, want := range []string{
		"[docs-guard]",
		"claude-code-guide",
		"WebFetch",
		"https://docs.claude.com/en/docs/claude-code/",
		"https://docs.claude.com/en/api/",
		"https://docs.claude.com/en/docs/mcp",
		"https://docs.claude.com/en/api/agent-sdk/",
	} {
		if !strings.Contains(guardMessage, want) {
			t.Errorf("guardMessage missing %q", want)
		}
	}
}
