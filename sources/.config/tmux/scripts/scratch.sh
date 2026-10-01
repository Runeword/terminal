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
# server's pid, since ids restart with every server. The main server's
# @scratch-owners lists the owners that have one, so its hooks run gc only when
# one of them closes, not on every window close.

case "$1" in
  global) exec tmux -L scratch new-session -A -s scratch ;;
  session | window)
    read -r pid id <<EOF
$(tmux display-message -p "#{pid} #{${1}_id}")
EOF
    case "$(tmux show-options -gqv @scratch-owners) " in
      *" $id "*) ;;
      *) tmux set-option -ga @scratch-owners " $id" ;;
    esac
    exec tmux -L scratch new-session -A -s "$1-$pid-${id#?}"
    ;;
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
    # The survivors back as owner ids: session-<pid>-3 -> $3, window-<pid>-5 -> @5
    tmux set-option -g @scratch-owners "$(
      tmux -L scratch list-sessions -F '#{session_name}' 2>/dev/null |
        sed -n "s/^session-$pid-/ \$/p; s/^window-$pid-/ @/p" | tr -d '\n'
    )"
    ;;
esac
