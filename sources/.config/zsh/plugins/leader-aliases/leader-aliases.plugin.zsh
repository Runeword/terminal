# leader-aliases - a leader key for zsh. On an empty prompt, Space (or Enter)
# opens an fzf list of the chords in a table; typing a chord narrows the list,
# and its command runs, or is inserted for editing, as soon as one row is
# left. A chord that matches nothing is typed into the line as is. On any
# other line, Space and Enter do what they did before this file was sourced.
#
# Needs fzf 0.40 or newer and the leader-aliases binary, which renders and
# checks the table:
#
#   go install github.com/Runeword/terminal/packages/leader-aliases@latest
#
# Settings:
#
#   LEADER_ALIASES_FILE      the table, read at each press; by default
#                            $XDG_CONFIG_HOME/leader-aliases/leader.conf.
#                            example.conf, next to this file, shows the format.
#   LEADER_ALIASES_BINDINGS  0 when this file is sourced leaves Space and
#                            Enter unbound: bind _leader_aliases_space and
#                            _leader_aliases_enter yourself.
#
# leader-aliases-edit edits the table the way visudo edits sudoers.

# Where example.conf is, for the message a missing table shows.
typeset -g _leader_aliases_dir=${${(%):-%x}:A:h}
typeset -g _leader_aliases_default=${XDG_CONFIG_HOME:-$HOME/.config}/leader-aliases/leader.conf

# The picker. leader-aliases renders the table as one fzf row per chord: the
# displayed chord, command, group and description, then the hidden raw command
# and mode (run, insert, eval-run, eval-insert). The command column is fitted
# to $COLUMNS (long commands are cut with an ellipsis) so one wide entry
# cannot push the other columns off screen.
# fzf matches on the chord only and accepts as soon as one row is left; a
# chord that matches nothing is inserted into the line as typed. A table that
# is missing or fails to render (parse error, binary missing) is reported in
# the status line instead of silently offering nothing.
# A press starts as few processes as it can, since a process start can cost
# tens of milliseconds (macOS behind endpoint security): the rows are rendered
# once (_leader_aliases_rows), the pick is read with parameter expansions, and
# an accepted line fetches no suggestion.
_leader_aliases_pick() {
  local table="${1:-${LEADER_ALIASES_FILE:-$_leader_aliases_default}}"
  if [[ ! -e $table ]]; then
    zle -M "leader-aliases: no table at $table; $_leader_aliases_dir/example.conf shows the format"
    return 1
  fi
  # leader-aliases separates a row's fields with U+00A0 (no-break space).
  local sep=$'\302\240'
  local rows
  if ! _leader_aliases_rows "$table"; then
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
            return
          fi
        fi
        ;;
      *)
        LBUFFER+="$cmd "
        if [ "$mode" = run ]; then
          zle accept-line
          return
        fi
        ;;
    esac
  elif [ "$selected" ]; then
    # Nothing matched: the query as typed, without its leading ^. Space in the
    # picker types a backslash and a space, which fzf matches as a space
    # rather than as the start of a new search term; the line gets the space
    # alone.
    local query=${selected%%$'\n'*}
    query=${query#"^"}
    LBUFFER+=${query//'\ '/ }
  fi

  _leader_aliases_suggest
}

# Sets REPLY to the table's rendered rows, or fails with REPLY set to the
# renderer's error. The rows are kept per shell until the renderer, the table
# or the terminal width changes, so a press renders them again only after an
# edit or a resize; zstat (zsh/stat) reads the table's identity without
# starting a process. A save that keeps the size within the same second goes
# unseen until the next change.
_leader_aliases_rows() {
  local table=$1 key=
  local -A st
  if zmodload -F zsh/stat b:zstat 2>/dev/null && zstat -H st -- "$table" 2>/dev/null; then
    key="${commands[leader-aliases]} $table ${COLUMNS:-0} ${st[inode]} ${st[size]} ${st[mtime]} ${st[ctime]}"
    if [ "$key" = "${_leader_aliases_rows_key-}" ]; then
      REPLY=$_leader_aliases_rows
      return 0
    fi
  fi
  REPLY=$(leader-aliases -width "${COLUMNS:-0}" "$table" 2>&1) || return 1
  typeset -g _leader_aliases_rows_key="$key" _leader_aliases_rows="$REPLY"
}

# zsh-autosuggestions is optional: its widget is called only when it is loaded.
_leader_aliases_suggest() {
  if (( ${+widgets[autosuggest-fetch]} )); then
    zle autosuggest-fetch
  fi
}

# Edits the table the way visudo edits sudoers: in a copy, in $EDITOR. When
# the editor closes, leader-aliases -fmt lines up the copy's columns and
# checks it: a valid copy is written over the table, a broken one is reported
# and, unless declined, reopened at its broken line, so the table never holds
# a broken line. The copy lives under $XDG_CACHE_HOME, not /tmp: sandboxed
# sessions share /tmp, and one could slip a chord into the copy before it
# replaces the table. The table is written over in place, keeping the inode a
# sandbox pin bind-mounts.
leader-aliases-edit() {
  local table="${1:-${LEADER_ALIASES_FILE:-$_leader_aliases_default}}"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}" dir copy err line='' answer
  # $EDITOR can hold arguments (code --wait): split it into words the way
  # zsh's edit-command-line does.
  local -a editor=("${(@Q)${(z)${EDITOR:-vi}}}")
  if [ ! -w "$table" ]; then
    printf 'leader: %s is read-only\n' "$table" >&2
    return 1
  fi
  mkdir -p -- "$cache" && dir=$(mktemp -d "$cache/leader-edit.XXXXXX") || return 1
  copy=$dir/leader.conf
  command cp -- "$table" "$copy" || return 1
  while "${editor[@]}" ${line:+"+$line"} -- "$copy"; do
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

# The widgets Space and Enter had before this file was sourced, which they
# still run off an empty prompt. Called by name, so a plugin that bound the
# keys first (zsh-abbr, magic-enter) keeps working, and so do the wrappers of
# the ones that wrap widgets: zsh-autosuggestions fetches a suggestion after
# self-insert. One subshell reads both keys; sourced again, the file keeps what
# it read the first time instead of saving its own widgets.
(( ${+_leader_aliases_prev} )) || typeset -gA _leader_aliases_prev=(
  _leader_aliases_space self-insert
  _leader_aliases_enter accept-line
)
() {
  local binding widget
  for binding in "${(@f)$(builtin bindkey ' '; builtin bindkey '^M')}"; do
    widget=${binding##* }
    [[ $widget == _leader_aliases_* ]] && continue
    case $binding in
      '" "'*) _leader_aliases_prev[_leader_aliases_space]=$widget ;;
      '"^M"'*) _leader_aliases_prev[_leader_aliases_enter]=$widget ;;
    esac
  done
}

# The picker on an empty prompt; anywhere else (a non-empty line, a
# continuation line, a select or vared prompt) the key's previous widget.
# The names start with _, so zsh-autosuggestions leaves the widgets unwrapped:
# wrapped, they would fetch a suggestion even after a line is accepted.
_leader_aliases_key() {
  if [[ -n $BUFFER || $CONTEXT != start ]]; then
    zle "${_leader_aliases_prev[$WIDGET]}"
    return
  fi
  _leader_aliases_pick
  zle redisplay
}
zle -N _leader_aliases_space _leader_aliases_key
zle -N _leader_aliases_enter _leader_aliases_key

if [[ ${LEADER_ALIASES_BINDINGS:-1} != 0 ]]; then
  bindkey -M emacs ' ' _leader_aliases_space '^M' _leader_aliases_enter
  bindkey -M viins ' ' _leader_aliases_space '^M' _leader_aliases_enter
fi
