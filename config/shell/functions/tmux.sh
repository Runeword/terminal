#!/bin/sh

__tmux_switch_session() {
  if [ "$(tmux list-sessions 2>/dev/null)" = "" ]; then
		trap 'return' INT
		printf 'new session name : ' && read -r input

		tmux new-session ${input:+-s"$input"}

		return 1
	fi

  local session_id
  session_id=$(tmux display-message -p '#{session_id}')

  local item_pos
  item_pos=$(tmux list-sessions -F '#{session_id}' | awk '{if ($1 == "'"$session_id"'") print NR}')

# --delimiter=' ' \
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
			${TMUX:+--bind='focus:execute-silent(tmux switch-client -t {1})'} \
			${TMUX:+--bind="load:pos($item_pos)"}
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
	local window

	window_id=$(tmux display-message -p '#{window_id}')
	item_pos=$(tmux list-windows -a -F '#{window_id}' | awk '{if ($1 == "'$window_id'") print NR}')

	window=$(
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
			${TMUX:+--bind='focus:execute-silent(tmux switch-client -t {4}; tmux select-window -t {3})'} \
			${TMUX:+--bind="load:pos($item_pos)"}
	)
}

__tmux_new_session() {
	local max_session session_name
	max_session=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
	session_name=$((${max_session:-0} + 1))

	session=$(tmux new-session -d -s"$session_name" -P -F "#{session_name}")

	if [ -n "$TMUX" ]; then
		tmux switch-client -t "$session"
	else
		tmux attach-session -t "$session"
	fi
}

__tmux_kill_session() {
  tmux switch-client -n
  tmux kill-session -t "$(tmux display-message -p "#S")" || tmux kill-session
}

__tmux_attach_session() {
  local session current
  [ -n "$TMUX" ] && current=$(tmux display-message -p '#S')
  session=$(tmux ls -F '#{session_name}|#{?session_attached,attached,not attached}|#{session_activity}' 2>/dev/null | awk -F'|' -v current="$current" '$2 == "attached" && $1 != current {print $1; exit} $2 == "not attached" && $1 != current && ($3 > max_activity || !found) {found=1; max_activity=$3; unattached=$1} END {if (unattached) print unattached}')

  if [ -n "$session" ]; then
    if [ -n "$TMUX" ]; then
      tmux switch-client -t "$session"
    else
      tmux attach -t "$session"
    fi
  else
    tmux new-session
  fi
}

__tmux_kill_pane() {
  local pane_count window_count session_count
  pane_count=$(tmux display-message -p '#{window_panes}')
  window_count=$(tmux display-message -p '#{session_windows}')
  session_count=$(tmux list-sessions | wc -l)

  if [ "$pane_count" -gt 1 ]; then
    tmux kill-pane
  elif [ "$window_count" -gt 1 ]; then
    tmux kill-window
  elif [ "$session_count" -gt 1 ]; then
    local current_session current_index prev_index prev_session
    current_session=$(tmux display-message -p '#S')
    current_index=$(tmux list-sessions -F '#{session_name}' | sort -V | awk -v sess="$current_session" '{if ($1 == sess) print NR}')

    [ "$current_index" -eq 1 ] && prev_index=$session_count || prev_index=$((current_index - 1))
    prev_session=$(tmux list-sessions -F '#{session_name}' | sort -V | sed -n "${prev_index}p")

    tmux switch-client -t "$prev_session"
    tmux kill-session -t "$current_session"
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

  tmux capture-pane -epJS - | sed 's/ \{10,\}.*$//' > "$tmpfile"

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
