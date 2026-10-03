#!/bin/bash

__tmux_switch_session() {
  if [ "$(tmux list-sessions 2>/dev/null)" = "" ]; then
    trap 'return' INT
    printf 'new session name : ' && read -r input

    # An empty name would let tmux fall back to naming the session after its id,
    # which starts at 0; __tmux_new_session numbers from 1 like base-index does.
    if [ "$input" = "" ]; then
      __tmux_new_session
    else
      tmux new-session -s "$input"
    fi

    return 1
  fi

  local session_id
  session_id=$(tmux display-message -p '#{session_id}')

  local item_pos
  item_pos=$(tmux list-sessions -F '#{session_id}' | awk '{if ($1 == "'"$session_id"'") print NR}')

  local session
  session=$(
    tmux ls -F "#{session_name}" 2>/dev/null | fzf \
      --reverse \
      --cycle \
      --height 50% \
      --no-separator \
      --prompt='  ' \
      --reverse \
      --info=inline:'' \
      --bind='tab:down,btab:up' \
      --bind='enter:execute(echo {1})+abort' \
      "${TMUX:+--bind="focus:execute-silent(tmux switch-client -t {1})"}" \
      "${TMUX:+--bind="load:pos($item_pos)"}"
  )

  [ "$session" = "" ] && return 1

  if [ "$TMUX" != "" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

__tmux_switch_window() {
  local item_pos
  local window_id

  window_id=$(tmux display-message -p '#{window_id}')
  item_pos=$(tmux list-windows -a -F '#{window_id}' | awk '{if ($1 == "'"$window_id"'") print NR}')

  # A row is "<session><window> <window id> <session id>": three fields, read
  # from the end ({-1}, {-2}) because a window name can hold spaces.
  tmux list-windows -a -F '#{session_name}#{window_name} #{window_id} #{session_id}' 2>/dev/null | fzf \
    --with-nth='1,2' \
    --reverse \
    --cycle \
    --height 50% \
    --delimiter=' ' \
    --prompt='  ' \
    --reverse \
    --no-separator \
    --info=inline:'' \
    --bind='tab:down,btab:up' \
    "${TMUX:+--bind="focus:execute-silent(tmux switch-client -t {-1}; tmux select-window -t {-2})"}" \
    "${TMUX:+--bind="load:pos($item_pos)"}" \
    >/dev/null
}

__tmux_swap_or_create_window() {
  local target_index="$1"
  local current_index
  current_index=$(tmux display-message -p '#{window_index}')

  if [ "$current_index" = "$target_index" ]; then
    local last_index
    last_index=$(tmux display-message -t '{last}' -p '#{window_index}' 2>/dev/null)
    [ "$last_index" = "" ] && return 0
    tmux swap-window -t "$last_index" \; select-window -t "$last_index"
  elif tmux list-windows -F '#{window_index}' | grep -qx "$target_index"; then
    tmux swap-window -t "$target_index" \; select-window -t "$target_index"
  else
    local current_path
    current_path=$(tmux display-message -p '#{pane_current_path}')
    tmux new-window -t ":$target_index" -c "$current_path"
  fi

  __tmux_flash_current_window
}

__tmux_new_session() {
  local max_session session_name
  max_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  session_name=$((${max_session:-0} + 1))

  session=$(tmux new-session -d -s"$session_name" -P -F "#{session_name}")

  if [ "$TMUX" != "" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

# Compact numerically-named sessions back to a gap-free 1..N -- the session-level
# analogue of renumber-windows. Wired to the session-closed hook in tmux.conf, so
# killing a middle session (2 of 1,2,3) closes the gap (-> 1,2) instead of leaving
# 1,3, and an attached session simply follows its own rename. Non-numeric session
# names are left untouched. Renaming the k-th smallest name to k (ascending) is
# collision-free: the k-th smallest is always >= k, so its target slot is free.
#
# It also refreshes every client's status line: tmux only flags a redraw for
# clients attached to the session that changed, but status-left lists all sessions
# (#{S:...}) on every bar, so a client on another session would otherwise show the
# killed/renamed sessions until the next status-interval tick (windows never lag).
#
# This runs on every session close and its latency is visible, so it is kept to
# two tmux round-trips and a single awk pass: one call reads the session names and
# the client list, awk emits the whole command batch (renames + a refresh per
# client), and one 'source-file -' applies it. That is ~2x faster than looping
# rename/refresh in the shell -- close to the fixed cost of the hook's own fork.
__tmux_renumber_sessions() {
  tmux list-sessions -F 'S #{session_name}' ';' list-clients -F 'C #{client_name}' 2>/dev/null |
    awk '
      /^S [0-9]+$/ { s[++ns] = $2 }
      /^C /        { c[++nc] = $2 }
      END {
        for (i = 2; i <= ns; i++) {   # numeric insertion sort (ns is tiny)
          v = s[i]; j = i - 1
          while (j >= 1 && s[j] > v) { s[j + 1] = s[j]; j-- }
          s[j + 1] = v
        }
        for (i = 1; i <= ns; i++)     # rename k-th smallest -> k where they differ
          if (s[i] != i) printf "rename-session -t =%s %d\n", s[i], i
        for (i = 1; i <= nc; i++)     # force each client status line to redraw now
          printf "refresh-client -S -t %s\n", c[i]
      }' |
    tmux source-file -
}

# Swap the grabbed session's number with its neighbour ($2 = +1 / -1) so a mouse
# drag reorders the number-sorted status-left. tmux has no swap-session and orders
# #{S:} by creation, so reordering means trading the two numeric names (via a temp).
# $1 is the grabbed session's current name; the drag bindings pass #{client_session},
# which follows the grabbed session across the renames. No-op at the 1..N ends.
__tmux_drag_session() {
  local num="$1" dir="$2" target
  case "$num" in '' | *[!0-9]*) return 0 ;; esac
  target=$((num + dir))
  [ "$target" -ge 1 ] || return 0
  tmux has-session -t "=$target" 2>/dev/null || return 0
  # Batch the three renames through one source-file so the status bar redraws once:
  # a rename-per-client would flash the temp name and shift the centred window list.
  printf 'rename-session -t =%s __tmux_drag_swap\nrename-session -t =%s %s\nrename-session -t =__tmux_drag_swap %s\n' \
    "$num" "$target" "$num" "$target" | tmux source-file -
}

# Kill the current session and move focus to the PREVIOUS session (wrapping past
# the first back to the last), batching switch + kill so there is no flicker. The
# focused, lower-numbered survivor keeps its number, so nothing needs renaming in
# the batch; the session-closed hook then compacts the hole the kill leaves behind.
# Reached from M-w / M-W (tmux.conf) when the last window of a session closes.
__tmux_kill_session() {
  local session_count current_session session_list current_index prev_index target
  session_count=$(tmux list-sessions | wc -l)
  current_session=$(tmux display-message -p '#S')

  if [ "$session_count" -le 1 ]; then
    tmux kill-session -t "=$current_session"
    return
  fi

  session_list=$(tmux list-sessions -F '#{session_name}' | sort -V)
  current_index=$(echo "$session_list" | awk -v sess="$current_session" '{if ($1 == sess) print NR}')

  # Focus the PREVIOUS session; from the first, wrap back to the last.
  if [ "$current_index" -eq 1 ]; then
    prev_index=$session_count
  else
    prev_index=$((current_index - 1))
  fi
  target=$(echo "$session_list" | sed -n "${prev_index}p")
  tmux switch-client -t "=$target" \; kill-session -t "=$current_session"
}

__tmux_attach_session() {
  local session current
  [ "$TMUX" != "" ] && current=$(tmux display-message -p '#S')

  session=$(tmux ls -F '#{session_attached} #{session_activity} #{session_name}' 2>/dev/null |
    awk -v current="$current" '$3 != current' |
    sort -k1,1nr -k2,2nr |
    awk 'NR==1 {print $3}')

  [ "$session" = "" ] && session=$(tmux ls -F '#{session_name}' 2>/dev/null | head -1)

  if [ "$session" != "" ]; then
    if [ "$TMUX" != "" ]; then
      tmux switch-client -t "=$session"
    else
      tmux attach -t "=$session"
    fi
  else
    __tmux_new_session
  fi
}

__tmux_move_window_to_session() {
  local direction="${1:-next}"
  local current_session target_session session_count current_index target_index

  session_count=$(tmux list-sessions | wc -l)

  # Exit if only one session exists
  if [ "$session_count" -le 1 ]; then
    return 1
  fi

  current_session=$(tmux display-message -p '#S')
  current_index=$(tmux list-sessions -F '#{session_name}' | sort -V | awk -v sess="$current_session" '{if ($1 == sess) print NR}')

  # Calculate target session index
  if [ "$direction" = "next" ]; then
    if [ "$current_index" -eq "$session_count" ]; then
      target_index=1
    else
      target_index=$((current_index + 1))
    fi
  else
    if [ "$current_index" -eq 1 ]; then
      target_index=$session_count
    else
      target_index=$((current_index - 1))
    fi
  fi

  target_session=$(tmux list-sessions -F '#{session_name}' | sort -V | sed -n "${target_index}p")

  # Switch first, in the same command: moving a session's only window destroys
  # that session, and detach-on-destroy (on by default) detaches the clients
  # still on it, so a switch-client after the move would have no client left.
  # -s names the window up front, since the switch makes the target current.
  tmux switch-client -t "=$target_session" \; \
    move-window -s "$(tmux display-message -p '#{window_id}')" -t "=$target_session:"
}

# Move the current window to the numerically-named session $1 (the M-S-<n> range in
# tmux.conf), following it there -- the by-number analogue of __tmux_move_window_to_session
# (next/prev), as C-S-<n> is the by-index analogue of window selection. No-op if $1 is
# already the current session or no session is named $1 (matching M-<n>, which does
# nothing past the last session rather than clamping to it). Resolve the target to its
# session_id up front: moving the current session's last window empties and destroys it,
# and the session-closed hook then renumbers survivors, so the target's *name* can change
# mid-operation while its id cannot -- the switch and move below must use the id.
__tmux_move_window_to_session_number() {
  local target="$1" current_session target_id src_win src_idx
  case "$target" in '' | *[!0-9]*) return 0 ;; esac

  current_session=$(tmux display-message -p '#S')
  [ "$target" = "$current_session" ] && return 0

  target_id=$(tmux list-sessions -f "#{==:#{session_name},$target}" -F '#{session_id}' 2>/dev/null)
  [ "$target_id" = "" ] && return 0

  src_win=$(tmux display-message -p '#{window_id}')
  src_idx=$(tmux display-message -p '#{window_index}')

  # Keep the window's own index number in the destination: if that index is taken, insert
  # before the occupant (-b) so the window takes it and the rest shift up; otherwise drop it
  # at exactly that index -- even past the session's end, leaving a gap, so the window always
  # keeps its number. Switch first, in the same command: tmux redraws once (a separate
  # switch-client would repaint the source session, then the target, which flickers), and
  # the client has left the source session before the move can empty it -- detach-on-destroy,
  # on by default, would otherwise detach it along with the session.
  if tmux list-windows -t "$target_id" -F '#{window_index}' | grep -qx "$src_idx"; then
    tmux switch-client -t "$target_id" \; move-window -s "$src_win" -b -t "$target_id:$src_idx"
  else
    tmux switch-client -t "$target_id" \; move-window -s "$src_win" -t "$target_id:$src_idx"
  fi
}

__tmux_open_url() {
  if ! command -v tmux >/dev/null 2>&1 || [ "$TMUX" = "" ]; then
    return 1
  fi

  local input
  input="$(tmux capture-pane -p -S -3000)"

  local urls
  urls="$(
    echo "$input" |
      grep -oP 'https?://[^\s<>"{}|\\^`\[\]]+' |
      awk '!seen[$0]++' |
      fzf --tac --multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'
  )"

  if [ "$urls" != "" ]; then
    echo "$urls" | while IFS= read -r url; do
      setsid xdg-open "$url" >/dev/null 2>&1 || setsid open "$url" >/dev/null 2>&1 &
    done
  fi
}

__tmux_flash_current_window() {
  tmux set -g window-status-current-format "#[fg=#ffffff,bold]#I #W"
  sleep 0.25
  tmux set -g window-status-current-format "#[fg=#ffffff]#I #W"
}
