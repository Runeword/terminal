#!/bin/bash

function __yazi_cd() {
  local tmp
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return
  yazi "$@" --cwd-file="$tmp"
  if cwd="$(cat -- "$tmp")" && [ "$cwd" != "" ] && [ "$cwd" != "$PWD" ]; then
    # shellcheck disable=SC2164 # a failed cd must still reach the rm below
    builtin cd -- "$cwd"
  fi
  rm -f -- "$tmp"
}
