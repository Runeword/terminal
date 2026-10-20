#!/bin/sh

# pwd() {
#   builtin pwd | tee /dev/tty | {
#     if command -v pbcopy >/dev/null 2>&1; then
#       pbcopy
#     elif command -v wl-copy >/dev/null 2>&1; then
#       wl-copy
#     fi
#   }
# }

__paste() {
  if command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  elif command -v wl-paste >/dev/null 2>&1; then
    wl-paste
  fi
}

__copy() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  fi
}

# Prints the current directory and copies it, without a newline
__copy_path() {
  printf '%s\n' "$PWD"
  printf '%s' "$PWD" | __copy
}

# Writes the lines of $1 to $2 without repeats, keeping the first of each
__txt_dedup() {
  awk '!seen[$0]++' "$1" >"$2"
}
