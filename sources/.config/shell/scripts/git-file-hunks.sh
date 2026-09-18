#!/bin/sh
# Child hunk picker for the two-level ga / gru / grd picker (see __git_pick_files
# in .config/shell/functions/git.bash). The files picker binds
#   right:execute(git-file-hunks.sh {} <state-dir> <mode>)
# on the focused file; this lists that file's hunks for fzf to multiselect.
# <mode> selects the diff the hunks come from:
#   staged    git diff --cached  (gru: hunks to unstage)
#   unstaged  git diff           (ga: hunks to stage, grd: hunks to discard)
# The apply direction is the parent's business; here we only record which hunks.
#
#   Enter     save the picked hunk indices, return to the files picker
#   Left/Esc  return without changing this file's saved selection
#
# The selection is written to <state-dir>/<key>, where <key> is base64 of the
# path (a flat, collision-free filename); line 1 is the path, line 2 the
# space-joined indices. A file with no diff in that mode is a no-op (untracked
# files, or nothing staged/unstaged there).
set -u

file=$1
state_dir=$2
mode=${3:-unstaged}

case "$mode" in
  staged) diff=$(git diff --cached --unified=0 -- "$file") ;;
  *) diff=$(git diff --unified=0 -- "$file") ;;
esac
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
