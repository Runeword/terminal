#!/bin/sh
# Copy mode's copies pipe what they copy through here (tmux.conf). It drops the
# indentation every non-blank line shares on screen, such as the two columns
# Claude Code draws its replies in, and keeps the rest, so a block pastes as it
# reads. $1 holds the selection's corners, #{selection_start_x},
# #{selection_start_y}, #{selection_end_x}, #{selection_end_y} and
# #{rectangle_toggle}: a selection that starts past the indentation, where
# back-to-indentation leaves the cursor, copies a first line without it, and
# its top corner says where that line starts. A rectangle's lines all start at
# its left edge, and a copy without corners (copy-command) counts from column
# 0. The result becomes a paste buffer, and -w hands it to the clipboard of the
# client $2 names, or of the one tmux picks. A failure says so on that client
# rather than leave nothing copied without a word.
corners=$1 client=$2
case $client in '#{'*) client= ;; esac

fail() {
  tmux display-message ${client:+-c "$client"} "copy-dedent.sh: $1, so nothing was copied"
  exit 1
}

num() {
  case $1 in '' | *[!0-9]*) return 1 ;; esac
}

IFS=, read -r sx sy ex ey rect <<END
$corners
END
off=0
if [ "$rect" != 1 ] && num "$sx" && num "$sy" && num "$ex" && num "$ey"; then
  # The corner on the upper line, or the left one on a single line.
  if [ "$sy" -lt "$ey" ] || { [ "$sy" -eq "$ey" ] && [ "$sx" -le "$ex" ]; }; then
    off=$sx
  else
    off=$ex
  fi
fi

# The x keeps blank lines at the end, which $(...) would drop.
text=$(
  awk -v off="$off" '
    { line[NR] = $0 }
    /[^ ]/ {
      match($0, /^ */)
      ind = RLENGTH + (NR == 1 ? off : 0)
      if (min == "" || ind < min) min = ind
    }
    END {
      for (i = 1; i <= NR; i++) {
        cut = min - (i == 1 ? off : 0)
        if (min == "" || cut < 0) cut = 0
        printf "%s%s", substr(line[i], cut + 1), (i < NR ? "\n" : "")
      }
    }
  ' && printf x
) || fail "awk failed"
printf '%s' "${text%x}" | tmux load-buffer -w ${client:+-t "$client"} - || fail "tmux load-buffer failed"
