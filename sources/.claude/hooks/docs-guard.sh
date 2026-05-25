#!/bin/sh
# UserPromptSubmit hook: when a prompt concerns Claude/Anthropic tooling,
# inject a hard instruction to consult live official docs before answering.
# Converts the model's probabilistic "should use docs" instinct into a
# deterministic harness-enforced rule.

prompt=$(jq -r '.prompt // ""')

printf %s "$prompt" | grep -qiE \
  '(claude[ -]code|claude[ -]?api|anthropic[ -]?(api|sdk)|agent[ -]?sdk|claude_agent_sdk|@anthropic-ai/sdk|\bmcp\b|userpromptsubmit|posttooluse|pretooluse|sessionstart|subagentstop|stop[ -]?hook|slash[ -]?command|claude[ -]?(hook|skill|subagent|plugin|command)|claude\.md|claude.{0,40}(feature|release|changelog|version|doc)|\b(opus|sonnet|haiku)[ -]?[0-9])' ||
  exit 0

cat <<'EOF'
[docs-guard] The user's question concerns Claude Code, the Claude Agent SDK, the Claude API, or Anthropic tooling.

You MUST verify your answer against the live official documentation BEFORE responding from training data. Pick one:

1. `claude-code-guide` subagent — best for multi-page / research-shaped questions; it synthesizes across pages and cites sources.
2. `WebFetch` directly against the canonical docs — best when you know the specific page:
   - Claude Code: https://docs.claude.com/en/docs/claude-code/
   - Claude API:  https://docs.claude.com/en/api/
   - MCP:         https://docs.claude.com/en/docs/mcp
   - Agent SDK:   https://docs.claude.com/en/api/agent-sdk/

If, after attempting a lookup, you still answer from training data, state that explicitly so the user knows the answer may be stale.
EOF
