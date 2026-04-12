#!/bin/bash

__go_dev() {
  local src="$HOME/terminal/packages/custom"

  if [ "$1" = "clean" ]; then
    rm -f "$HOME/terminal/.direnv/bin/git-branches"
    echo "$(which git-branches)"
    return
  fi

  (builtin cd "$src/git-branches" && go build -o "$HOME/terminal/.direnv/bin/git-branches" .)
  echo "$HOME/terminal/.direnv/bin/git-branches"
}
