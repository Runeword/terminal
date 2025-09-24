__cd() {
  local target="$@"
  if [[ -z "$target" ]]; then
    # Handle 'cd' without arguments; change to the $HOME directory.
    target="$HOME"
  fi

  # Note, if the target directory is the same as the current directory
  # do nothing since we don't want to needlessly populate the directory stack
  # with repeat entries.
  if [[ "$target" != "$PWD" ]]; then
    \builtin pushd "$target" 1>/dev/null
    printf '\033[3m\033[90m%s\033[0m\n' "$PWD"
  fi
}

__nextd() {
  pushd -0 &>/dev/null
}

__prevd() {
  pushd +1 &>/dev/null
}
