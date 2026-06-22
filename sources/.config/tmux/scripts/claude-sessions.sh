#!/bin/sh
# Toggle a right-side pane showing the live status of every running Claude Code
# session (`claude-session-status watch`). The pane id is tracked in the
# window-local option @claude_pane, mirroring the @toggle_pane pattern in
# scripts/toggle-pane.sh, so each window toggles its own dashboard pane.

width="${1:-44}"

p=$(tmux show-option -wqv @claude_pane)

# A tracked pane exists: if it's still alive, close it (toggle off). If the
# handle is stale (pane already gone), drop it and fall through to recreate.
if [ "$p" != "" ]; then
  if tmux display-message -t "$p" -p '#{pane_id}' >/dev/null 2>&1; then
    tmux kill-pane -t "$p"
    tmux set-option -wu @claude_pane
    exit 0
  fi
  tmux set-option -wu @claude_pane
fi

# Toggle on: split a right-hand pane running the dashboard. -d keeps focus on
# the work pane; the command resolves from PATH (packages.tools).
p=$(tmux split-window -h -d -l "$width" -P -F '#{pane_id}' \
  -c "#{pane_current_path}" "claude-session-status watch")
tmux set-option -w @claude_pane "$p"
