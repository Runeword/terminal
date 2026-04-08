#!/bin/sh

__claude() {
  local instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
    shift
  fi

  if [ "$TMUX" != "" ]; then
    sh "$NIX_OUT_TMUX/.config/tmux/scripts/toggle-pane.sh" 15 \
      "CLAUDE_CONFIG_DIR='$HOME/.claude-$instance' command claude --effort max --model opus $(printf '%q ' "$@")"
  else
    CLAUDE_CONFIG_DIR="$HOME/.claude-$instance" command claude --effort max "$@"
  fi
}

__claude_connect_firefox() {
  CONNECT_EXISTING=true __claude "$@"
}
