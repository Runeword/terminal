---
description: Ask a panel of 3 independent expert subagents, then answer with the principles they agree on, their sources, and one pick
argument-hint: "<question>"
disable-model-invocation: true
---

Run an expert panel on this question: $ARGUMENTS

If no question is given, use the open question in this conversation.

1. Launch 3 fresh general-purpose subagents in one message, so they run in
   parallel. Not forks: a fork starts with this conversation and echoes it.
2. Give each one a different angle that fits the question. One of them is a
   devil's advocate.
3. Give each the same brief: the question, the constraints, and what this
   conversation already decided. A subagent sees no conversation and no
   memory, so the brief carries everything. Leave your own opinion out.
4. Each expert looks up what experts in its field recommend, with a web
   search, primary sources first: official docs, standards, well-known tools
   and books. It reports in under 300 words: the main principles, each with a
   named source, then one recommendation for this case.
5. When all three are back, answer with:
   - the principles they agree on, each with its source;
   - where they disagree, and why;
   - one clear pick for this case.

Use plain words. Don't give a new list of options.
