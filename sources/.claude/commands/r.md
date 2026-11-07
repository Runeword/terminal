---
description: Research the codebase with the built-in Explore agent, which reads and searches but doesn't edit
argument-hint: "<question>"
disable-model-invocation: true
context: fork
agent: Explore
background: false
---

Research this question in the current project: $ARGUMENTS

If no question is given, say that /r needs one and stop: this agent starts
without the conversation, so there is no open question to fall back on.

Read and search only. Never use a glob that matches every Nix store entry
and continues the path, like `/nix/store/*/bin/foo`: zsh's memory grows with
the square of the matches, and it once stalled the machine. Resolve a tool
with `readlink -f "$(command -v foo)"` instead.

Answer with file:line references.
