#!/bin/sh
# Child hunk picker for the two-level `ga` stager (see __git_add in
# .config/shell/functions/git.bash). The files picker binds
#   right:execute(git-add-hunks.sh {} <state-dir>)
# on the focused file; this lists that file's unstaged hunks (git-hunk-pick at
# zero context, so each separated change is its own selectable hunk) for fzf to
# multiselect.
#
#   Enter     save the picked hunk indices, return to the files picker
#   Left/Esc  return without changing this file's saved selection
#
# The selection is written to <state-dir>/<key>, where <key> is base64 of the
# path (a flat, collision-free filename); line 1 is the path, line 2 the
# space-joined indices. __git_add reads the dir at finalize to build the
# `git diff | git-hunk-pick assemble | git apply --cached` clauses. Untracked
# files and files with no unstaged change have no diff, so this is a no-op for
# them (the files picker stages those whole via Tab).
set -u

file=$1
state_dir=$2

diff=$(git diff --unified=0 -- "$file")
[ -n "$diff" ] || exit 0

tmpdiff=$(mktemp) || exit 1
trap 'rm -f "$tmpdiff"' EXIT
printf '%s\n' "$diff" >"$tmpdiff"

pager=$(git config core.pager 2>/dev/null || echo cat)

# fzf shows the hunk label (field 2..) but keeps the index (field 1) in its
# output; the preview renders just the focused hunk through the pager. Left
# aborts (fzf exits non-zero -> no save); Enter prints the marked rows.
selection=$(
  git-hunk-pick list <"$tmpdiff" |
    fzf \
      --reverse \
      --no-separator \
      --keep-right \
      --border none \
      --cycle \
      --height 70% \
      --info=inline: \
      --header-first \
      --header='← back · tab hunk · ⏎ save' \
      --prompt='  ' \
      --multi \
      --bind=ctrl-a:select-all \
      --bind=left:abort \
      --delimiter='\t' \
      --with-nth=2.. \
      --preview "echo {2..}; git-hunk-pick assemble {1} <$tmpdiff | $pager" \
      --preview-window=right,75%,border-none,wrap,~1
)

[ -n "$selection" ] || exit 0

indices=$(printf '%s\n' "$selection" | cut -f1 | tr '\n' ' ')
key=$(printf '%s' "$file" | base64 | tr -d '\n' | tr / _)
printf '%s\n%s\n' "$file" "$indices" >"$state_dir/$key"
