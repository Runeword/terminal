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
    "${TMUX:+--bind="focus:execute-silent(tmux switch-client -t {4}; tmux select-window -t {3})"}" \
    "${TMUX:+--bind="load:pos($item_pos)"}" \
    >/dev/null
}

__tmux_goto_window() {
  local target_index="$1"
  local current_index max_index
  current_index=$(tmux display-message -p '#{window_index}')

  # Clamp past-the-end presses onto the last window: C-9 in a 3-window session
  # selects window 3 instead of doing nothing.
  max_index=$(tmux list-windows -F '#{window_index}' | sort -n | tail -1)
  [ "$max_index" != "" ] && [ "$target_index" -gt "$max_index" ] && target_index="$max_index"

  if [ "$current_index" = "$target_index" ]; then
    tmux last-window
    return
  fi

  if tmux list-windows -F '#{window_index}' | grep -qx "$target_index"; then
    tmux select-window -t "$target_index"
  fi
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

# Kill the current session and move focus to the PREVIOUS session (wrapping past
# the first back to the last), batching switch + kill so there is no flicker. The
# focused, lower-numbered survivor keeps its number, so nothing needs renaming in
# the batch; the session-closed hook then compacts the hole the kill leaves behind.
# Reached via M-N / M-W, and via __tmux_kill_pane (M-w) when the last window closes.
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

__tmux_kill_pane() {
  local pane_count window_count session_count
  pane_count=$(tmux display-message -p '#{window_panes}')
  window_count=$(tmux display-message -p '#{session_windows}')
  session_count=$(tmux list-sessions | wc -l)

  if [ "$pane_count" -gt 1 ]; then
    # Keep focus on the current index: step to the NEXT pane -- the one that slides
    # into this slot once we kill -- then kill the pane we left, so killing pane 1
    # of 1|2|3 lands on the old pane 2 (now pane 1), not on the pane we came from.
    # On the last pane there is no next, so step back to the new last instead.
    local current_pane current_index last_index
    current_pane=$(tmux display-message -p '#{pane_id}')
    current_index=$(tmux display-message -p '#{pane_index}')
    last_index=$(tmux list-panes -F '#{pane_index}' | sort -n | tail -1)
    if [ "$current_index" -ge "$last_index" ]; then
      tmux select-pane -t '{previous}' \; kill-pane -t "$current_pane"
    else
      tmux select-pane -t '{next}' \; kill-pane -t "$current_pane"
    fi
  elif [ "$window_count" -gt 1 ]; then
    # Same index-preserving rule for windows: step to the NEXT window (renumber-
    # windows then slides it into our old index) and kill the one we left, so
    # killing window 1 lands on the old window 2, now renumbered to 1. On the last
    # window there is no next, so step back to the new last instead.
    local current_window last_window
    current_window=$(tmux display-message -p '#{window_index}')
    last_window=$(tmux list-windows -F '#{window_index}' | sort -n | tail -1)
    if [ "$current_window" -ge "$last_window" ]; then
      tmux select-window -p \; kill-window -t:"$current_window"
    else
      tmux select-window -n \; kill-window -t:"$current_window"
    fi
  elif [ "$session_count" -gt 1 ]; then
    # Last window/pane of this session -> kill the whole session. Focus moves to
    # the previous session; see __tmux_kill_session.
    __tmux_kill_session
  else
    tmux kill-pane
  fi
}

__tmux_nvim_copy_mode() {
  local tmpfile
  tmpfile=$(mktemp /tmp/tmux-buffer-XXXXXX)

  local cursor_x cursor_y scroll_position history_size
  cursor_x=$(tmux display-message -p '#{cursor_x}')
  cursor_y=$(tmux display-message -p '#{cursor_y}')
  scroll_position=$(tmux display-message -p '#{scroll_position}')
  history_size=$(tmux display-message -p '#{history_size}')

  tmux capture-pane -epJS - | sed 's/ \{10,\}.*$//' >"$tmpfile"

  local target_line target_col
  target_line=$((history_size - scroll_position + cursor_y + 1))
  target_col=$((cursor_x + 1))

  nvim -u ~/neovim/config/init-scrollback.lua \
    -c 'set clipboard=unnamedplus nonumber norelativenumber laststatus=0 cmdheight=0 noshowmode noruler signcolumn=no foldcolumn=0 nolist' \
    -c 'lua vim.o.winbar = "" vim.g.baleia.once(0)' \
    -c "normal! ${target_line}G${target_col}|" \
    "$tmpfile"

  rm -f "$tmpfile"
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

  tmux move-window -t "$target_session:"
  tmux switch-client -t "$target_session"
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

__tmux_save_window_state() {
  local history_file="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-window-history"
  local pane_path="$1"
  local pane_command="$2"

  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$history_file")"

  # Save path and command separated by ||| delimiter
  # Format: path|||command
  echo "$pane_path|||$pane_command" >>"$history_file"
  tail -20 "$history_file" >"$history_file.tmp" && mv "$history_file.tmp" "$history_file"
}

__tmux_reopen_window() {
  local history_file="${XDG_DATA_HOME:-$HOME/.local/share}/tmux-window-history"

  # Check if history file exists and has content
  if [ ! -f "$history_file" ] || [ ! -s "$history_file" ]; then
    tmux display-message "No closed windows to restore"
    return 0
  fi

  # Get the last closed window entry
  local last_entry last_path last_command
  last_entry=$(tail -1 "$history_file")

  # Remove the last entry from history
  sed -i '$ d' "$history_file" 2>/dev/null || sed -i '' '$ d' "$history_file" 2>/dev/null

  # Parse path and command (handle both old and new format)
  if echo "$last_entry" | grep -q '|||'; then
    last_path=$(echo "$last_entry" | cut -d'|' -f1)
    last_command=$(echo "$last_entry" | cut -d'|' -f4-)
  else
    # Old format - just path
    last_path="$last_entry"
    last_command=""
  fi

  # Create new window with the saved path
  if [ "$last_path" != "" ] && [ -d "$last_path" ]; then
    if [ "$last_command" = "claude" ]; then
      # The saved name comes from pane_current_command, and the sandbox launcher
      # deliberately execs into bwrap as "claude" so autorename and this
      # save/restore flow see the payload name. Restoring it verbatim therefore
      # runs the *binary* on PATH: no bubblewrap, and no CLAUDE_CONFIG_DIR, so it
      # falls back to the ~/.claude profile whose credentials the sandbox exists
      # to keep masked. Rebuild the real launch command instead, from the restored
      # path, so the launcher's cwd gate judges the directory the window will
      # actually open in.
      local claude_cmd
      # shellcheck disable=SC1091 # sourced from $PERMEANCE_TREE, resolved at runtime
      claude_cmd=$(
        cd "$last_path" &&
          . "$PERMEANCE_TREE/.config/shell/functions/claude.bash" &&
          __claude_init "" >/dev/null &&
          printf '%s' "$__CLAUDE_CMD"
      )
      if [ "$claude_cmd" = "" ]; then
        tmux new-window -a -c "$last_path"
        tmux display-message "Restored: $last_path (shell - claude refused to launch here)"
      else
        tmux new-window -a -c "$last_path" "$claude_cmd"
        tmux display-message "Restored: $last_path (claude)"
      fi
    elif [ "$last_command" != "" ] && [ "$last_command" != "zsh" ] && [ "$last_command" != "bash" ] && [ "$last_command" != "sh" ]; then
      # Create window and run the command
      tmux new-window -a -c "$last_path" "$last_command"
      tmux display-message "Restored: $last_path ($last_command)"
    else
      # Just create a shell window
      tmux new-window -a -c "$last_path"
      tmux display-message "Restored: $last_path (shell)"
    fi
  else
    tmux new-window -a
    tmux display-message "Restored (path invalid)"
  fi
}

__tmux_flash_current_window() {
  tmux set -g window-status-current-format "#[fg=#ffffff,bold]#I #W"
  sleep 0.25
  tmux set -g window-status-current-format "#[fg=#ffffff]#I #W"
}
