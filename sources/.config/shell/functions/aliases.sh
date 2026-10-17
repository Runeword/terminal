#!/bin/bash

__run_alias() {
  local name

  # Only the name comes from the picked line (bash lists `alias name='value'`, zsh
  # `name='value'`); the value comes from the shell's own alias table, so one
  # holding an `=` or a quote runs whole.
  name=$(alias |
    fzf \
      --delimiter='=' \
      --height 70% \
      --reverse \
      --prompt='  ' \
      --no-separator \
      --info=inline:'' |
    sed 's/^alias //;s/=.*//') || return 0
  [ -n "$name" ] || return 0

  # shellcheck disable=SC2154 # aliases is zsh's alias table
  if [ -n "$ZSH_VERSION" ]; then
    sh -c "${aliases[$name]}"
  else
    sh -c "${BASH_ALIASES[$name]}"
  fi
}

# Leader-key picker. leader-aliases (packages/leader-aliases) renders leader.conf
# as one fzf row per chord: the displayed chord, command, group and description,
# then the hidden raw command and mode (run, insert, eval-run, eval-insert).
# The command column is fitted to $COLUMNS (long commands are cut with an
# ellipsis) so one wide entry cannot push the other columns off screen.
# fzf matches on the chord only and accepts as soon as one row is left; a
# chord that matches nothing is inserted into the line as typed. A table that
# fails to render (parse error, binary missing) is reported in the status
# line instead of silently offering nothing.
# A press starts as few processes as it can, since a process start can cost
# tens of milliseconds (macOS behind endpoint security): the rows are rendered
# once (__aliases_rows), the pick is read with parameter expansions, and an
# accepted line fetches no suggestion. It always fails, which tells
# __on_empty_buffer the prompt is unchanged, so the line is only redrawn.
__aliases() {
  local table="${1:-$PERMEANCE_TREE/.config/shell/leader.conf}"
  # leader-aliases separates a row's fields with U+00A0 (no-break space).
  local sep=$'\302\240'
  local rows
  if ! __aliases_rows "$table"; then
    zle -M "${REPLY:-leader-aliases: failed to render $table}"
    return 1
  fi
  rows=$REPLY

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
        --delimiter="$sep" \
        --cycle \
        --no-preview \
        --reverse \
        --no-sort \
        --prompt='  ' \
        --bind 'one:accept,zero:accept,tab:accept' \
        --bind 'space:put(\ )' \
        --height 70%
  ); then
    # fzf printed the query, then the picked row, whose last two fields are the
    # raw command and the mode: leader-aliases keeps the separator out of every
    # field.
    local row cmd mode
    row=${selected#*$'\n'}
    mode=${row##*"$sep"}
    row=${row%"$sep"*}
    cmd=${row##*"$sep"}

    case "$mode" in
      eval-run | eval-insert)
        local output
        zle redisplay
        output=$(eval "$cmd")
        if [ -n "$output" ]; then
          LBUFFER+=$output
          if [ "$mode" = eval-run ]; then
            zle accept-line
            return 1
          fi
        fi
        ;;
      *)
        LBUFFER+="$cmd "
        if [ "$mode" = run ]; then
          zle accept-line
          return 1
        fi
        ;;
    esac
  elif [ "$selected" ]; then
    # Nothing matched: the query as typed, without its leading ^.
    local query=${selected%%$'\n'*}
    LBUFFER+=${query#"^"}
  fi

  zle autosuggest-fetch

  return 1
}

# Sets REPLY to the table's rendered rows, or fails with REPLY set to the
# renderer's error. The rows are kept per shell until the renderer, the table
# or the terminal width changes, so a press renders them again only after an
# edit or a resize; zstat (zsh/stat) reads the table's identity without
# starting a process. A save that keeps the size within the same second goes
# unseen until the next change.
__aliases_rows() {
  # The renderer's name goes through a variable: as a bare subscript, shfmt
  # would read leader-aliases as arithmetic and rewrite it to leader - aliases.
  local table=$1 renderer=leader-aliases key=
  local -A st
  # shellcheck disable=SC2154 # commands is zsh's command table
  if zmodload -F zsh/stat b:zstat 2>/dev/null && zstat -H st -- "$table" 2>/dev/null; then
    key="${commands[$renderer]} $table ${COLUMNS:-0} ${st[inode]} ${st[size]} ${st[mtime]} ${st[ctime]}"
    if [ "$key" = "${__aliases_rows_key-}" ]; then
      REPLY=$__aliases_rows
      return 0
    fi
  fi
  REPLY=$(leader-aliases -width "${COLUMNS:-0}" "$table" 2>&1) || return 1
  typeset -g __aliases_rows_key="$key" __aliases_rows="$REPLY"
}

# Edits the leader table (leader oa) the way visudo edits sudoers: in a copy,
# in $EDITOR. When the editor closes, leader-aliases -fmt lines up the copy's
# columns and checks it: a valid copy is written over the table, a broken one
# is reported and, unless declined, reopened at its broken line, so the table
# never holds a broken line. The copy lives under $XDG_CACHE_HOME, not /tmp:
# sandboxed sessions share /tmp, and one could slip a chord into the copy
# before it replaces the table. The table is written over in place, keeping
# the inode a sandbox pin bind-mounts.
__leader_edit() {
  local table="${1:-$PERMEANCE_TREE/.config/shell/leader.conf}"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}" dir copy err line='' answer
  if [ ! -w "$table" ]; then
    printf 'leader: %s is read-only\n' "$table" >&2
    return 1
  fi
  mkdir -p -- "$cache" && dir=$(mktemp -d "$cache/leader-edit.XXXXXX") || return 1
  copy=$dir/leader.conf
  command cp -- "$table" "$copy" || return 1
  while "${EDITOR:-vi}" ${line:+"+$line"} -- "$copy"; do
    if err=$(leader-aliases -fmt "$copy" 2>&1); then
      cat -- "$copy" >|"$table" && rm -rf -- "$dir"
      return
    fi
    printf '%s\nEdit it again? [Y/n] ' "$err" >&2
    read -r answer
    case $answer in
      [nN]*) break ;;
    esac
    line=${err##*"$copy":}
    line=${line%%:*}
    case $line in
      '' | *[!0-9]*) line= ;;
    esac
  done
  printf 'leader: the table is unchanged; the edit is in %s\n' "$copy" >&2
  return 1
}
