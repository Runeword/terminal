# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# zr (zoxide.sh).

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# zr lists zoxide's directories after their scores, keeps them in score
# order while a query filters them, and removes the ones picked in fzf,
# keeping the rest: a stand-in fzf records the rows it is offered and
# those the real one picks, by path, for a query that matches the first
# and the last of three, the last a path with a space that fzf's own
# ranking would put first.
zoxide_remove='. @zsh@/.config/shell/functions/zoxide.sh
  export _ZO_DATA_DIR=$HOME/zoxide
  mkdir -p "$_ZO_DATA_DIR" "$HOME/z/a" "$HOME/z/b" "$HOME/z/c d"
  zoxide add "$HOME/z/a" "$HOME/z/b" "$HOME/z/c d"
  zoxide add "$HOME/z/a" "$HOME/z/b"
  zoxide add "$HOME/z/a"
  fzf() { tee "$HOME/zr-offered" | @fzf@/bin/fzf --filter="a$ | d$" "$@" | tee "$HOME/zr-picked"; }
  __zoxide_remove && zoxide query --list'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^zr +$/ && $5 == "__zoxide_remove" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(PATH=@zoxide@/bin:$PATH @zsh@/bin/zsh -f -c "$zoxide_remove")" = "$HOME/z/b" ] &&
  [ "$(awk '{ print $1 }' "$HOME/zr-offered" | tr '\n' ' ')" = "12.0 8.0 4.0 " ] &&
  [ "$(awk -F / '{ print $NF }' "$HOME/zr-picked" | tr '\n' ,)" = "a,c d," ]; then
  ok "zr lists zoxide's directories after their scores, in score order while a query filters them, and removes the ones picked in fzf"
else
  fail "zr does not list the directories after their scores, or not in score order while a query filters them, or does not remove the ones picked in fzf, or removes others"
fi
