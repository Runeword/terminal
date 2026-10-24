#!/bin/sh
# M-t (tmux.conf) runs this instead of new-window once the current session has
# @wmax windows. The window still opens after the current one, and the windows
# after it shift one place right: the session's last window moves to a new
# session next to it, numbered after it, and the sessions after it, in the
# order of their numbers as the status bar shows them, move one number up. A
# session with no number puts the new session after the last, as
# __tmux_new_session numbers them. When the current window is the session's
# last, the new window is the one that moves, and the client follows it.
# Either way it starts in the current pane's directory, as M-t's own windows
# do.
#
# M-t passes its session's id, the client that pressed it (a job's own tmux
# calls would otherwise fall back to the most recently active session), its
# window, 1 when that window is the session's last, and the pane's directory,
# with any # doubled: new-window expands -c as a format.

current=$1 client=$2 window=$3 last=$4 path=$5

# One tmux call for every step, so no client draws the sessions halfway. The
# first line is the new session's number, and each line after it names a
# session that moves one number up: highest first, so the number it takes is
# free.
{
  read -r new
  set --
  while read -r id to; do
    set -- "$@" rename-session -t "$id" "$to" \;
  done
} <<EOF
$(tmux list-sessions -F '#{session_id} #{session_name}' |
  awk -v current="$current" '
    NF == 2 && $2 ~ /^[0-9]+$/ {
      id[$2 + 0] = $1
      if ($2 + 0 > end) end = $2 + 0
      if ($1 == current) at = $2 + 1
    }
    END {
      if (at == "") at = end + 1
      print at
      n = at
      while (n in id) n++
      while (--n >= at) print id[n], n + 1
    }')
EOF
# A session starts with a window: the moved window replaces a stand-in.
set -- "$@" new-window -a -t "$window" -c "$path" \; new-session -d -s "$new" sleep 1 \; \
  move-window -k -s "$current:{end}" -t "=$new:{start}"
if [ "$last" = 1 ]; then
  set -- "$@" \; switch-client -c "$client" -t "=$new:{start}"
fi
tmux "$@"
