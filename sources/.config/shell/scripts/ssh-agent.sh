#!/bin/sh

if ! pgrep -u "$USER" ssh-agent >/dev/null; then
  ssh-agent -t 2h >"$XDG_RUNTIME_DIR/ssh-agent.env"
fi
if [ "$SSH_AUTH_SOCK" = "" ]; then
  # shellcheck source=/dev/null # written by ssh-agent above
  . "$XDG_RUNTIME_DIR/ssh-agent.env" >/dev/null
fi
