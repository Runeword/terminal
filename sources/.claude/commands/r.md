---
description: Research the codebase with the read-only Explore agent
argument-hint: "<question>"
disable-model-invocation: true
context: fork
agent: Explore
background: false
---

Research this question in the current project: $ARGUMENTS

If no question is given, say that /r needs one and stop: this agent starts
without the conversation, so there is no open question to fall back on.

Answer with file:line references.
