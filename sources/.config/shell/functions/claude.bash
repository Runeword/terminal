#!/bin/bash
# shellcheck disable=SC2153

__CLAUDE_FZF="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
__CLAUDE_DEFAULT_PLUGINS=(nix-mcp nix-lsp typescript-lsp)

# Build __CLAUDE_CMD from __claude_instance, __claude_plugins, __claude_args.
__claude_build_cmd() {
  local args
  args=$(printf '%q ' "$__claude_args")
  # __CLAUDE_CMD="CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance command claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-4-5-20251101 $args"
  __CLAUDE_CMD="CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance command claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-4-7 $args"
}

__claude_init() {
  __claude_instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    __claude_instance="$1"
    shift
  fi
  __claude_args="$*"

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  __claude_plugins=""
  for p in "${__CLAUDE_DEFAULT_PLUGINS[@]}"; do
    [ -d "$plugins_dir/$p" ] && __claude_plugins="$__claude_plugins --plugin-dir $plugins_dir/$p"
  done

  __claude_build_cmd
}

__claude_init_fzf() {
  __claude_instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    __claude_instance="$1"
    shift
  fi
  __claude_args="$*"

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  local selected
  selected=$(find -L "$plugins_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | eval fzf --multi "$__CLAUDE_FZF") || return 1
  __claude_plugins=$(echo "$selected" | while IFS= read -r p; do
    [ "$p" != "" ] && printf ' --plugin-dir %s/%s' "$plugins_dir" "$p"
  done)

  __claude_build_cmd
}

__claude_run() {
  local size="${1:-15}"
  if [ -n "$TMUX" ]; then
    local script="$PERMEANCE_ROOT/.config/tmux/scripts/toggle-pane.sh"
    tmux run-shell "sh $script $size $__CLAUDE_CMD"
  else
    eval "$__CLAUDE_CMD"
  fi
}

__claude() {
  __claude_init "$@" || return 0
  __claude_run 15
}

__claude_plugins() {
  __claude_init_fzf "$@" || return 0
  __claude_run 15
}

__claude_debug() {
  __claude_init "$@" || return 0

  local file="/tmp/claude-debug.log"
  touch "$file"
  if [ -n "$TMUX" ]; then
    local script="$PERMEANCE_ROOT/.config/tmux/scripts/toggle-pane.sh"
    tmux run-shell "sh $script 50 tail -f $file"
    tmux swap-pane -U \; select-pane -D
  fi
  __CLAUDE_CMD="CLAUDE_CODE_DEBUG_LOG_LEVEL=verbose $__CLAUDE_CMD --debug --debug-file $file"
  eval "$__CLAUDE_CMD"
}
