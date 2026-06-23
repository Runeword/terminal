#!/bin/sh
# Toggle a bottom pane running the flake watcher (`watch` with no args, which
# defaults to `nix flake check` — rebuild every wrapper + the terminal and run
# the smoke tests on each .nix write). The pane id is tracked in the
# window-local option @watch_pane, mirroring the @claude_pane pattern in
# scripts/claude-sessions.sh, so each window toggles its own build pane.

height="${1:-8}"

p=$(tmux show-option -wqv @watch_pane)

# A tracked pane exists: if it's still alive, close it (toggle off). If the
# handle is stale (pane already gone), drop it and fall through to recreate.
if [ "$p" != "" ]; then
  if tmux display-message -t "$p" -p '#{pane_id}' >/dev/null 2>&1; then
    tmux kill-pane -t "$p"
    tmux set-option -wu @watch_pane
    exit 0
  fi
  tmux set-option -wu @watch_pane
fi

# Toggle on. The `watch` helper lives in the dev shell (not packages.tools), so
# reach it via `nix develop` against the repo that owns the current pane's dir.
pane_path=$(tmux display-message -p '#{pane_current_path}')
repo=$(git -C "$pane_path" rev-parse --show-toplevel 2>/dev/null)
if [ "$repo" = "" ]; then
  tmux display-message "watch-build: not inside a git repo"
  exit 0
fi

# -d keeps focus on the work pane; toggle off (same key) or Ctrl-C to stop.
p=$(tmux split-window -v -d -l "$height" -P -F '#{pane_id}' \
  -c "$repo" "nix develop \"$repo\" --command watch")
tmux set-option -w @watch_pane "$p"
