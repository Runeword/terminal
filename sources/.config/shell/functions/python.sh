#!/bin/sh

# Recreates .venv with python3.12 and activates it in this shell
__python_venv_recreate() {
  rm -r .venv 2>/dev/null
  # shellcheck source=/dev/null # created by the line above
  python3.12 -m venv .venv && . .venv/bin/activate
}

# Lists the Python versions installed with Homebrew
__python_brew_list() {
  brew list | grep python
}
