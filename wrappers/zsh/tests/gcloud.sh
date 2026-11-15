# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# gc (gcloud.bash): its secret › set and project › set.

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# gc's secret › set reads the value silently and hands it to gcloud on
# stdin, so it never reaches the command line or the shell history.
secret='. @zsh@/.config/shell/functions/gcloud.bash
  gcloud() { print -r -- "$* <$(cat)>"; }
  __gcloud_secret_set name'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$5 == "__gcloud_secret_set <secret>" { found = 1 } END { exit !found }' &&
  grep -q 'read -rs' @zsh@/.config/shell/functions/gcloud.bash &&
  [ "$(echo s3cret | @zsh@/bin/zsh -f -c "$secret" 2>/dev/null)" = "secrets versions add name --data-file=- <s3cret>" ]; then
  ok "gc's secret › set reads the value silently and hands it to gcloud on stdin"
else
  fail "gc's secret › set echoes the value or puts it on the command line"
fi

# gc's project › set offers gcloud's projects in fzf and sets the
# picked one; stand-ins list two projects and pick the second.
project='. @zsh@/.config/shell/functions/gcloud.bash
  gcloud() { [ "$1" = projects ] && print -l a-1 b-2 || print -r -- "$*"; }
  fzf() { tail -n 1; }
  __gcloud_project_set'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$5 == "__gcloud_project_set" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(@zsh@/bin/zsh -f -c "$project" 2>/dev/null)" = "config set project b-2" ]; then
  ok "gc's project › set sets the project picked in fzf"
else
  fail "gc's project › set does not set the project picked in fzf"
fi
