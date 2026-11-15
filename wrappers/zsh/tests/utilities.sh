# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# yp (utilities.sh).

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# yp prints the current directory and copies it without a newline; a
# stand-in __copy records what it was handed.
copy='. @zsh@/.config/shell/functions/utilities.sh
  __copy() { cat > "$HOME/copied"; }
  cd / && __copy_path'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^yp +$/ && $5 == "__copy_path" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(@zsh@/bin/zsh -f -c "$copy")" = / ] &&
  [ "$(
    cat "$HOME/copied"
    echo .
  )" = /. ]; then
  ok "yp prints the current directory and copies it without a newline"
else
  fail "yp does not print and copy the current directory as it is"
fi
