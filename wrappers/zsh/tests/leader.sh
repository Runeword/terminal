# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# The leader key (the leader-aliases plugin and shell/leader.conf): the
# table renders, the picker reuses its rows and runs each kind of chord, and
# ol edits the table in a copy.

# A leader.conf that fails to render leaves every chord dead, so check
# the fields the widget reads (raw command, mode) for a known chord.
sep=$(printf '\302\240')
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^gt +$/ && $5 == "git status" && $6 == "run" { found = 1 } END { exit !found }'; then
  ok "bundled leader.conf renders and binds gt to git status"
else
  fail "bundled leader.conf does not render the gt chord"
fi

# The picker renders the table once per shell and width: a second press
# reuses the rows, a resize or an edited table renders them again. A
# stand-in leader-aliases counts the renders.
mkdir -p "$HOME/leader/bin"
cp @zsh@/.config/shell/leader.conf "$HOME/leader/leader.conf"
chmod u+w "$HOME/leader/leader.conf"
printf '#!/bin/sh\necho >> "%s"\nexec %s "$@"\n' "$HOME/leader/renders" @leaderAliases@/bin/leader-aliases >"$HOME/leader/bin/leader-aliases"
chmod +x "$HOME/leader/bin/leader-aliases"
rows='. @zsh@/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh
  t=$HOME/leader/leader.conf
  COLUMNS=100; _leader_aliases_rows "$t"; first=$REPLY
  _leader_aliases_rows "$t"; [ "$REPLY" = "$first" ] && print same
  COLUMNS=90; _leader_aliases_rows "$t"
  print "# edited" >> "$t"; _leader_aliases_rows "$t"'
if [ "$(PATH=$HOME/leader/bin:$PATH @zsh@/bin/zsh -f -c "$rows")" = same ] &&
  [ "$(wc -l <"$HOME/leader/renders")" -eq 3 ]; then
  ok "the leader picker renders its table once, then again only after a resize or an edit"
else
  fail "the leader picker does not reuse its rows until a resize or an edit"
fi

# ol (leader-aliases-edit) edits the table in a copy that reaches it only
# valid and lined up: a stand-in editor, which takes an argument the way
# EDITOR='code --wait' does, adds a line with an unknown mode, then,
# reopened at that line, fixes it.
printf '[git]\ngt  run  status  git status\n' >"$HOME/leader/edit.conf"
printf '#!/bin/sh\n[ "$1" = -w ] || exit 1; shift\necho "$*" >> "%s"\nfor f; do :; done\ncase $1 in\n  --) echo "zz  rnu  sleep  sleep 1" >> "$f" ;;\n  +3) sed "s/ rnu / run /" "$f" > "$f.new" && cat "$f.new" > "$f" ;;\nesac\n' \
  "$HOME/leader/edits" >"$HOME/leader/bin/edit"
chmod +x "$HOME/leader/bin/edit"
edit='. @zsh@/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh; leader-aliases-edit "$HOME/leader/edit.conf"'
if echo y | EDITOR='edit -w' PATH=$HOME/leader/bin:$PATH @zsh@/bin/zsh -f -c "$edit" 2>/dev/null &&
  [ "$(cat "$HOME/leader/edit.conf")" = "$(printf '[git]\ngt \trun \tstatus \tgit status\nzz \trun \tsleep  \tsleep 1')" ] &&
  [ "$(awk '{ print $1 }' "$HOME/leader/edits" | tr '\n' ' ')" = "-- +3 " ]; then
  ok "ol runs an EDITOR with arguments, reopens the table copy at a broken line and writes it back lined up"
else
  fail "ol does not run an EDITOR with arguments, does not reopen a broken line, or writes the table back broken or unaligned"
fi

# The picker reads its pick without starting a process, and the widget
# then only redraws the line: reset-prompt would re-expand the prompt,
# rerunning starship twice, before an accepted command even starts. Nor
# does an accepted line fetch a suggestion. A stand-in zle records the
# widgets called; a stand-in fzf prints what fzf --print-query would,
# the query and the chord's row. leader-aliases goes on the path inside
# the script: zsh -i reads /etc/zshenv, and nix-darwin's (in an
# unsandboxed build) resets PATH.
stubs='path=(@leaderAliases@/bin $path)
  zle() { print -r -- "zle $*"; }
  pick() { print -r -- "^$1"; grep -m 1 "^$1 *$SEP"; }
  __nix_package() { print -r -- "nix $1 nixpkgs#hello"; }'
picker() {
  SEP=$sep @zsh@/bin/zsh -i -c "$stubs
    $1"'
    BUFFER= CONTEXT=start; _leader_aliases_key
    print -r -- "LBUFFER=$LBUFFER"' 2>/dev/null
}
picked=$(picker 'fzf() { pick gt; }')
case "$picked" in
  *"$(printf 'zle accept-line\nzle redisplay\nLBUFFER=git status ')") ok "a run chord (gt) accepts its command, then only redraws the line" ;;
  *) fail "a run chord (gt) does not accept its command with a bare redraw: $picked" ;;
esac
picked=$(picker 'fzf() { pick nps; }')
case "$picked" in
  *"$(printf 'zle redisplay\nzle accept-line\nzle redisplay\nLBUFFER=nix shell nixpkgs#hello')") ok "an eval chord (nps) runs its helper and accepts its output between bare redraws" ;;
  *) fail "an eval chord (nps) re-expands the prompt or does not accept its helper's output: $picked" ;;
esac
picked=$(picker 'fzf() { print -r -- "^z\ z"; return 1; }')
case "$picked" in
  *"$(printf 'zle autosuggest-fetch\nzle redisplay\nLBUFFER=z z')") ok "a chord that matches nothing is inserted as typed, without its ^ or the backslash fzf puts before a space" ;;
  *) fail "a chord that matches nothing is not inserted as typed: $picked" ;;
esac

# Alt+Space (_leader_aliases_line) opens the picker on a typed line: a
# chord holding #LINE (ls: sudo #LINE) puts its command in place of the
# line, the cursor on the same character; any other chord, a run chord
# (gt) too, goes in at the cursor and is not run. The buffers stand in
# for the typed line, split at the cursor.
typed() {
  SEP=$sep @zsh@/bin/zsh -i -c "$stubs
    fzf() { pick $1; }
    BUFFER='$2$3' LBUFFER='$2' RBUFFER='$3'"'
    _leader_aliases_line
    print -r -- "[$LBUFFER|$RBUFFER]"' 2>/dev/null
}
picked="$(typed ls apt ' install foo')$(typed gt 'time ' "")"
case "$picked" in
  *'[sudo apt| install foo]'*"$(printf 'zle autosuggest-fetch\nzle redisplay\n[time git status |]')") ok "on a typed line, a #LINE chord (ls) replaces the line around the cursor, and a run chord (gt) is only inserted at the cursor" ;;
  *) fail "on a typed line, a #LINE chord does not replace the line around the cursor, or a run chord is run or misplaced: $picked" ;;
esac

# Off an empty prompt, Space and Enter run the widgets they had before
# the plugin was sourced, in a bare zsh with no .zshrc and no
# zsh-autosuggestions: a stand-in zle records the widgets called on a
# non-empty line and on an empty select prompt.
bare='. @zsh@/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh
  zle() { print -r -- "zle $*"; }
  BUFFER=ls CONTEXT=start WIDGET=_leader_aliases_space _leader_aliases_key
  BUFFER= CONTEXT=select WIDGET=_leader_aliases_enter _leader_aliases_key'
if [ "$(@zsh@/bin/zsh -f -c "$bare" 2>&1)" = "$(printf 'zle self-insert\nzle accept-line')" ]; then
  ok "off an empty prompt, Space and Enter run their previous widgets, in a bare zsh"
else
  fail "off an empty prompt, Space or Enter does not run its previous widget in a bare zsh"
fi

# The plugin's example.conf, the table it points newcomers to, renders
# and is lined up the way -fmt writes it.
example=@zsh@/.config/zsh/plugins/leader-aliases/example.conf
if @leaderAliases@/bin/leader-aliases "$example" >/dev/null &&
  [ "$(@leaderAliases@/bin/leader-aliases -fmt - <"$example")" = "$(cat "$example")" ]; then
  ok "the leader plugin's example.conf renders and is lined up"
else
  fail "the leader plugin's example.conf does not render, or is not lined up"
fi
