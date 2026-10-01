#!/bin/sh
# Scratch terminals kept on their own tmux server (-L scratch), out of the main
# session flow: a global one, one per session and one per window (C-Space,
# M-Space and C-M-Space in tmux.conf).
#
#   scratch.sh global|session|window   command of a main-server display-popup:
#                                      attach that scratch, creating it if needed
#   scratch.sh gc                      main-server hooks: kill the session and
#                                      window scratches whose owner is gone
#
# A session or window scratch is named after its owner's id, which survives the
# session renumbering and a window moving to another session, plus the main
# server's pid, since ids restart with every server.

# session-<pid>-<n> for $n, window-<pid>-<n> for @n, as seen by the main server
name() {
  tmux display-message -p "$1-#{pid}-#{${1}_id}" | tr -d '$@'
}

case "$1" in
  global) exec tmux -L scratch new-session -A -s scratch ;;
  session | window) exec tmux -L scratch new-session -A -s "$(name "$1")" ;;
  gc)
    pid=$(tmux display-message -p '#{pid}')
    live=$({
      tmux list-sessions -F 'session-#{pid}-#{session_id}'
      tmux list-windows -a -F 'window-#{pid}-#{window_id}'
    } | tr -d '$@')
    tmux -L scratch list-sessions -F '#{session_name}' 2>/dev/null |
      while read -r s; do
        case "$s" in
          session-*-* | window-*-*) ;;
          *) continue ;;
        esac
        owner=${s#*-}
        owner=${owner%%-*}
        if [ "$owner" = "$pid" ]; then
          printf '%s\n' "$live" | grep -qx "$s" && continue
        elif kill -0 "$owner" 2>/dev/null; then
          continue # another main server's, still running
        fi
        tmux -L scratch kill-session -t "=$s" 2>/dev/null || :
      done
    ;;
esac
