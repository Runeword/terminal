#!/bin/sh

# Interactively selects and removes one or more directories from zoxide's list
# (Tab marks several)
__zoxide_remove() {
  local selected
  selected=$(
    zoxide query --list |
      fzf --multi --info=inline:'' --reverse --no-separator --prompt='  ' --border none --cycle --height 70% --header-first --bind='ctrl-a:select-all' --header="zoxide remove"
  )

  [ "$selected" = "" ] && return 1

  # NUL-separated, so a path with blanks stays one argument
  printf '%s\n' "$selected" | tr '\n' '\0' | xargs -0 zoxide remove
}
