#!/bin/sh

# Interactively selects and removes one or more directories from zoxide's list,
# each shown after its score (Tab marks several)
__zoxide_remove() {
  local selected
  # The delimiter matches only the leading score, so fzf searches and prints the
  # path alone, trailing blanks included
  selected=$(
    zoxide query --list --score |
      fzf --multi --delimiter='^ *[0-9.]+ ' --nth=2 --accept-nth=2 --info=inline:'' --reverse --no-separator --prompt='  ' --border none --cycle --height 70% --header-first --bind='ctrl-a:select-all' --header="zoxide remove"
  )

  [ "$selected" = "" ] && return 1

  # NUL-separated, so a path with blanks stays one argument
  printf '%s\n' "$selected" | tr '\n' '\0' | xargs -0 zoxide remove
}
