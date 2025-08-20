pwd() {
  builtin pwd | tee /dev/tty | {
    if command -v pbcopy >/dev/null 2>&1; then
      pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then
      wl-copy
    fi
  }
}
