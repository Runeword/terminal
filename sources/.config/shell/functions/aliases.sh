#!/bin/bash

__run_alias() {
  local name

  # Only the name comes from the picked line (bash lists `alias name='value'`, zsh
  # `name='value'`); the value comes from the shell's own alias table, so one
  # holding an `=` or a quote runs whole.
  name=$(alias |
    fzf \
      --delimiter='=' \
      --height 70% \
      --reverse \
      --prompt='  ' \
      --no-separator \
      --info=inline:'' |
    sed 's/^alias //;s/=.*//') || return 0
  [ -n "$name" ] || return 0

  # shellcheck disable=SC2154 # aliases is zsh's alias table
  if [ -n "$ZSH_VERSION" ]; then
    sh -c "${aliases[$name]}"
  else
    sh -c "${BASH_ALIASES[$name]}"
  fi
}
