#!/bin/bash

__cd() {
  local target="$*"
  if [ -z "$target" ]; then
    # Handle 'cd' without arguments; change to the $HOME directory.
    target="$HOME"
  fi

  # Note, if the target directory is the same as the current directory
  # do nothing since we don't want to needlessly populate the directory stack
  # with repeat entries.
  if [ "$target" != "$PWD" ]; then
    builtin pushd "$target" >/dev/null 2>&1 || return 1
    printf '\033[38;2;83;94;115m%s\033[0m\n' "$PWD"
  fi
}

__nextd() {
  pushd -0 >/dev/null 2>&1 || return 1
}

__prevd() {
  pushd +1 >/dev/null 2>&1 || return 1
}
