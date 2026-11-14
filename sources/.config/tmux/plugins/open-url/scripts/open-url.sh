#!/bin/sh
# The key open-url.tmux binds in copy mode (C-Enter) runs this to open the link
# under the cursor in the browser; copy mode stays as it was. It gets the pane,
# and the client that pressed the key, which is told when the cursor is on no
# link.
#
# A link a program marked as one (OSC 8: Claude's Markdown links, which show
# only their text) is tmux's copy_cursor_hyperlink. Otherwise it is the http(s)
# URL in copy_cursor_word, the word under the cursor, which tmux follows onto
# the next line when the URL wrapped. That word also ends at word-separators,
# which a URL is full of (: / .), so they are emptied for that one read, which
# leaves only spaces, and put back from @ws right after. The binding runs this
# without -b, so keys pressed meanwhile wait, and none moves by words with the
# separators emptied. The URL then loses what prose puts after a link: . , ; :
# ! ? ' and a ) or ] that closes nothing in the URL (a Wikipedia link keeps
# its own).

pane=$1 client=$2

found=$(tmux set -gF @ws '#{word-separators}' \; set -g word-separators '' \; \
  display -p -t "$pane" '#{copy_cursor_hyperlink}' \; \
  display -p -t "$pane" '#{copy_cursor_word}')
tmux set -gF word-separators '#{@ws}' \; set -gu @ws

url=$(printf '%s\n' "$found" | awk '
  NR == 1 && /^https?:\/\// { print; exit }
  NR == 2 && match($0, /https?:\/\/[^<>"{}|\\^`]+/) {
    url = substr($0, RSTART, RLENGTH)
    for (;;) {
      end = substr(url, length(url))
      if (end ~ /[.,;:!?\047]/ ||
        end == ")" && gsub(/\(/, "(", url) < gsub(/\)/, ")", url) ||
        end == "]" && gsub(/\[/, "[", url) < gsub(/]/, "]", url))
        url = substr(url, 1, length(url) - 1)
      else
        break
    }
    print url
  }')

if [ -z "$url" ]; then
  tmux display -c "$client" 'No link under the cursor'
  exit 0
fi

# In the background, detached: xdg-open can wait for a browser it starts, and
# the keys wait for this script.
if command -v xdg-open >/dev/null 2>&1; then opener=xdg-open; else opener=open; fi
if command -v setsid >/dev/null 2>&1; then
  setsid "$opener" "$url" </dev/null >/dev/null 2>&1 &
else
  "$opener" "$url" </dev/null >/dev/null 2>&1 &
fi
