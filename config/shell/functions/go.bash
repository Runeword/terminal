#!/bin/bash

__go_dev() {
  local src="$HOME/terminal/packages/custom"
  local bin="$HOME/terminal/.direnv/bin"

  if [ "$1" = "clean" ]; then
    rm -f "$bin/git-branches" "$bin/claude-statusline"
    echo "Cleaned dev builds. Falling back to Nix store:"
    echo "  $(which git-branches)"
    echo "  claude-statusline (via Claude wrapper PATH)"
    return
  fi

  mkdir -p "$bin"
  (builtin cd "$src/git-branches" && go build -o "$bin/git-branches" .)
  (builtin cd "$src/claude-statusline" && go build -o "$bin/claude-statusline" .)
  echo "Built: $bin/git-branches $bin/claude-statusline"
}
