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
