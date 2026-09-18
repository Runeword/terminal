#!/bin/sh
# shellcheck disable=SC3003,SC3024

__run_alias() {
  local selected

  selected=$(alias |
    fzf \
      --delimiter='=' \
      --height 70% \
      --reverse \
      --prompt='  ' \
      --no-separator \
      --info=inline:'' |
    awk -F'=' '{print $2}' | sed "s/^'//;s/'$//") || return 0

  sh -c "$selected"
}

# Leader-key picker. leader-aliases (packages/custom) renders leader.toml as
# one fzf row per chord: the displayed chord, command, group and description,
# then the hidden raw command and mode (run, insert, eval-run, eval-insert).
# The command column is fitted to $COLUMNS (long commands are cut with an
# ellipsis) so one wide entry cannot push the other columns off screen.
# fzf matches on the chord only and accepts as soon as one row is left; a
# chord that matches nothing is inserted into the line as typed. A table that
# fails to render (parse error, binary missing) is reported in the status
# line instead of silently offering nothing.
__aliases() {
  local table="${1:-$PERMEANCE_TREE/.config/shell/leader.toml}"
  local rows
  if ! rows=$(leader-aliases -width "${COLUMNS:-0}" "$table" 2>&1); then
    zle -M "${rows:-leader-aliases: failed to render $table}"
    return 1
  fi

  local selected
  if selected=$(
    printf '%s\n' "$rows" |
      fzf -i \
        --with-nth=1,2,3,4 \
        --print-query \
        --query "^" \
        --exact \
        --nth=1 \
        --no-info \
        --no-separator \
        --delimiter=$' ' \
        --cycle \
        --no-preview \
        --reverse \
        --no-sort \
        --prompt='  ' \
        --bind 'one:accept,zero:accept,tab:accept' \
        --bind 'space:put(\ )' \
        --height 70%
  ); then
    local cmd mode
    cmd=$(printf '%s\n' "$selected" | awk -F $' ' 'NR == 2 { print $5 }')
    mode=$(printf '%s\n' "$selected" | awk -F $' ' 'NR == 2 { print $6 }')

    case "$mode" in
      eval-run | eval-insert)
        local output
        zle reset-prompt
        output=$(eval "$cmd")
        if [ -n "$output" ]; then
          LBUFFER+=$output
          [ "$mode" = eval-run ] && zle accept-line
        fi
        ;;
      *)
        LBUFFER+="$cmd "
        [ "$mode" = run ] && zle accept-line
        ;;
    esac
  elif [ "$selected" ]; then
    LBUFFER+=$(printf '%s\n' "$selected" | sed -n '1p' | sed 's/^\^//')
  fi

  zle autosuggest-fetch

  return 1
}
