#!/bin/sh
# Toggle a paired pane between minimized and expanded sizes.
# If no pane exists and a command is given, create one.

min_size="${1:-0}"
shift
cmd="$*"

p=$(tmux show-option -wqv @toggle_pane)

# Check if pane still exists
if [ "$p" != "" ]; then
  h=$(tmux display-message -t "$p" -p '#{pane_height}' 2>/dev/null)
  if [ "$h" = "" ]; then
    tmux set-option -wu @toggle_pane
    p=""
  fi
fi

# Create pane if none exists and a command was given
if [ "$p" = "" ]; then
  [ "$cmd" = "" ] && exit 0
  max_size=$((100 - min_size))
  pane_path=$(tmux display-message -p '#{pane_current_path}')
  p=$(tmux split-window -v -l "${max_size}%" -P -F '#{pane_id}' -c "$pane_path" "$cmd")
  tmux set-option -w @toggle_pane "$p"
  exit 0
fi

IFS=' ' read -r c z w <<EOF
$(tmux display-message -p '#{pane_id} #{window_zoomed_flag} #{window_height}')
EOF

if [ "$min_size" -eq 0 ]; then
  if [ "$z" = "1" ]; then
    tmux resize-pane -Z \; select-pane -t "$p"
  elif [ "$c" = "$p" ]; then
    tmux select-pane -t :.+ \; resize-pane -Z
  else
    tmux resize-pane -Z
  fi
  exit 0
fi

pct=$((h * 100 / w))

max_size=$((100 - min_size))

if [ "$pct" -le "$((min_size + 5))" ]; then
  # Expand: resize first (invisible while zoomed), then unzoom
  if [ "$z" = "1" ]; then
    tmux resize-pane -t "$p" -y "${max_size}%" \; resize-pane -Z \; select-pane -t "$p"
  else
    tmux resize-pane -t "$p" -y "${max_size}%" \; select-pane -t "$p"
  fi
elif [ "$c" = "$p" ]; then
  # Shrink + move focus away
  if [ "$z" = "1" ]; then
    tmux resize-pane -t "$p" -y "${min_size}%" \; resize-pane -Z \; select-pane -t :.+
  else
    tmux select-pane -t :.+ \; resize-pane -t "$p" -y "${min_size}%"
  fi
else
  # Shrink
  if [ "$z" = "1" ]; then
    tmux resize-pane -t "$p" -y "${min_size}%" \; resize-pane -Z
  else
    tmux resize-pane -t "$p" -y "${min_size}%"
  fi
fi
