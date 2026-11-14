#!/bin/sh
# open-url, a tmux plugin: in copy mode, C-Enter opens the link under the
# cursor in the browser, and copy mode stays. Load it from tmux.conf with
#   run-shell /path/to/open-url/open-url.tmux
# and to bind another key, set it before that line: set -g @open-url-key M-o
# scripts/open-url.sh finds the link and opens it.

dir=$(cd "$(dirname "$0")" && pwd)
key=$(tmux show -gqv @open-url-key)
key=${key:-C-Enter}
open="sh '$dir/scripts/open-url.sh' #{pane_id} #{q:client_name}"

tmux bind-key -T copy-mode-vi "$key" run-shell "$open" \; \
  bind-key -T copy-mode "$key" run-shell "$open"
