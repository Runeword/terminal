#!/bin/sh
# M-t (tmux.conf) runs this instead of new-window once the current session has
# @wmax windows. The window still opens after the current one, and the windows
# after it shift one place right, on into the next sessions in the order of
# their numbers, as the status bar shows them: the session's last window moves
# to the front of the next session, which passes its own last window on when it
# is full too, and a new session, numbered after the last as __tmux_new_session
# numbers them, takes the window that no session has room for. When the current
# window is the session's last, the new window is the one that moves on, and
# the client follows it. Either way it starts in the current pane's directory,
# as M-t's own windows do.
#
# M-t passes @wmax, its session's id, the client that pressed it (a job's own
# tmux calls would otherwise fall back to the most recently active session),
# its window, 1 when that window is the session's last, and the pane's
# directory, with any # doubled: new-window expands -c as a format.

max=$1 current=$2 client=$3 window=$4 last=$5 path=$6

# One tmux call for every step, so no client draws the windows halfway.
set -- new-window -a -t "$window" -c "$path"
first=
# Each line names a session that passes its last window on and the session
# that takes it: = and a number for a new session.
while read -r from to; do
  case $to in
    =*)
      # A session starts with a window: the moved window replaces a stand-in.
      set -- "$@" \; new-session -d -s "${to#=}" sleep 1 \; move-window -k -s "$from:{end}" -t "$to:{start}"
      ;;
    *) set -- "$@" \; move-window -d -s "$from:{end}" -b -t "$to:{start}" ;;
  esac
  first=${first:-$to}
done <<EOF
$(tmux list-sessions -F '#{session_windows} #{session_id} #{session_name}' |
  awk -v max="$max" -v current="$current" '
    NF == 3 && $3 ~ /^[0-9]+$/ {
      id[$3 + 0] = $2
      full[$3 + 0] = $1 + 0 >= max + 0
      if ($3 + 0 > end) end = $3 + 0
      if ($2 == current) start = $3 + 1
    }
    END {
      from = current
      for (n = start; n <= end; n++)
        if (n in id) {
          print from, id[n]
          if (!full[n]) exit
          from = id[n]
        }
      print from, "=" end + 1
    }')
EOF
if [ "$last" = 1 ]; then
  set -- "$@" \; switch-client -c "$client" -t "$first:{start}"
fi
tmux "$@"
