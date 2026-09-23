#!/bin/sh
# Child hunk picker for the two-level ga / gru / grd / gsp picker (see
# __git_pick_files in .config/shell/functions/git.bash). The files picker binds
#   {enter,right}:execute(git-file-hunks.sh {} <state-dir> <mode> <via> <verb> {+f})
# on the focused file; this lists that file's hunks for fzf to multiselect.
# <mode> selects the diff the hunks come from:
#   staged    git diff --cached  (gru: hunks to unstage)
#   unstaged  git diff           (ga: hunks to stage; grd / gsp)
# <via> is the parent key that drilled in (enter|right); <verb> only labels header.
# {+f} is the parent's NATIVE selection (one path per line) — see `marks` below.
#
# Drilled hunk specs live in the shared state file <state-dir>/.sel (git-file-select.sh
# owns the format): two lines per tracked path — the path, then its spec:
#   ALL          every hunk — the whole file
#   <indices>    a space-joined subset of hunk indices — apply just those
# Whole-file selection itself is fzf's NATIVE multi-select in the PARENT, not a .sel
# entry, so a Tab-marked-whole file arrives here with no spec: we detect it via the
# parent's {+f} and open it fully marked (ALL). This script reads/writes one path's
# spec via `git-file-select.sh get/set`. Drilling pre-marks the saved spec (ALL -> all
# hunks, a subset -> those); leaving all hunks marked saves ALL, a subset saves the
# indices, and nothing marked clears it.
#
#   Enter     save the selection, then finalize the picker (drop .execute, which
#             the parent's transform turns into the command)
#   Left/Esc  return to the files picker, keeping the selection
# A file with no diff here has no hunks: Enter finalizes at once, Right is a no-op.
set -u

file=$1
state_dir=$2
mode=${3:-unstaged}
via=${4:-right}
verb=${5:-execute}
# $6 is the parent picker's NATIVE selection ({+f}: one path per line), meaningful
# only when the parent had marks. Whole-file selection is fzf's native multi-select
# now, not a .sel spec, so this is how a Tab-marked-whole file tells us it is selected.
marks=${6:-}
parent_sel=${FZF_SELECT_COUNT:-0}

# The sibling state helper reads/writes this file's spec in the shared .sel.
sel_helper="$(dirname "$0")/git-file-select.sh"

case "$mode" in
  staged) diff=$(git diff --cached --unified=0 -- "$file") ;;
  *) diff=$(git diff --unified=0 -- "$file") ;;
esac

if [ -z "$diff" ]; then
  # No hunks here (untracked / unchanged). Enter finalizes the current selection
  # (smart Enter); Right is a no-op. Such a file is staged only if it was Tab-marked
  # whole in the files list — the parent captures its native selection on finalize.
  [ "$via" = enter ] && : >"$state_dir/.execute"
  exit 0
fi

tmpdiff=$(mktemp) || exit 1
trap 'rm -f "$tmpdiff"' EXIT
printf '%s\n' "$diff" >"$tmpdiff"

pager=$(git config core.pager 2>/dev/null || echo cat)

# Start from the saved spec: ALL -> select-all; a subset -> pos(N)+select per index
# (git-hunk-pick lists hunk N at row N). Bound to `load` (not `start`, which the
# global fzf opts use for hidden-search); reset to top after. The indices are
# integers written by this script, so the word-split is safe.
spec=$(sh "$sel_helper" get "$state_dir" "$file")

# A Tab-marked-whole file carries no .sel spec — it lives in the parent's native
# selection. If this file is natively selected but unspec'd, open it fully marked
# (ALL) so an accidental drill (and its WYSIWYG save below) can't silently drop it.
if [ -z "$spec" ] && [ "$parent_sel" -gt 0 ] && [ -n "$marks" ] && [ -f "$marks" ] &&
  grep -qxF -- "$file" "$marks"; then
  spec=ALL
fi

preselect=""
if [ "$spec" = ALL ]; then
  preselect="select-all+"
elif [ -n "$spec" ]; then
  # shellcheck disable=SC2086
  for i in $spec; do
    preselect="${preselect}pos($i)+select+"
  done
fi

hunks=$(git-hunk-pick list <"$tmpdiff")
total=$(printf '%s\n' "$hunks" | grep -c .)

# fzf shows the hunk label (field 2..) but keeps the index (field 1) in its
# output. Enter executes: it writes the .execute sentinel the parent's transform
# acts on, and prints the marked rows. Left and Esc just return to the files
# picker (Esc is bound because the global esc toggles search instead of aborting).
# Each become is guarded by FZF_SELECT_COUNT, so it emits only what is marked.
# ctrl-a keeps $FZF_SELECT_COUNT/$FZF_MATCH_COUNT single-quoted so fzf (not the
# shell) expands them; the shell formatter collapses the double-quoted form back
# to this, so silence SC2016 for the block instead of fighting it.
# shellcheck disable=SC2016
selection=$(
  printf '%s\n' "$hunks" |
    fzf \
      --reverse \
      --no-separator \
      --keep-right \
      --border none \
      --cycle \
      --height 70% \
      --info=inline: \
      --header-first \
      --header="← back · tab hunk · ⏎ $verb" \
      --prompt='  ' \
      --multi \
      --bind "tab:select+down" \
      --bind "btab:deselect+up" \
      --bind 'ctrl-a:transform([ "${FZF_SELECT_COUNT:-0}" -eq "${FZF_MATCH_COUNT:-0}" ] && echo deselect-all || echo select-all)' \
      --bind "load:${preselect}first" \
      --bind "enter:become(: >\"$state_dir/.execute\"; test \${FZF_SELECT_COUNT:-0} -gt 0 && printf '%s\\n' {+})" \
      --bind "left:become(test \${FZF_SELECT_COUNT:-0} -gt 0 && printf '%s\\n' {+})" \
      --bind "esc:become(test \${FZF_SELECT_COUNT:-0} -gt 0 && printf '%s\\n' {+})" \
      --delimiter='\t' \
      --with-nth=2.. \
      --preview "echo {2..}; git-hunk-pick assemble {1} <$tmpdiff | $pager" \
      --preview-window=right,75%,border-none,wrap,~1
)

# Record the spec WYSIWYG: all hunks -> ALL (whole file); a subset -> its indices;
# nothing marked -> clear it in .sel (the file is deselected).
if [ -n "$selection" ]; then
  sel_count=$(printf '%s\n' "$selection" | grep -c .)
  if [ "$sel_count" -ge "$total" ]; then
    sh "$sel_helper" set "$state_dir" "$file" ALL
  else
    indices=$(printf '%s\n' "$selection" | cut -f1 | tr '\n' ' ')
    sh "$sel_helper" set "$state_dir" "$file" "$indices"
  fi
else
  sh "$sel_helper" set "$state_dir" "$file" ""
fi
