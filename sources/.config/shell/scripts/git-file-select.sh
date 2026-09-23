#!/bin/sh
# State helper for the two-level files picker (see __git_pick_files in
# .config/shell/functions/git.bash). Whole-file selection is fzf's OWN native
# multi-select (Tab = toggle, in-process, no subprocess), so this helper is off
# the Tab hot path. It tracks only DRILLED hunk specs, in one file <sd>/.sel,
# two lines per tracked path: the path, then its spec:
#   ALL          whole file (a drill that kept every hunk)
#   <indices>    space-joined hunk indices — a partial selection
# A path absent from .sel has no drilled spec (it is whole iff natively selected).
# Native selection itself lives in fzf; on finalize the parent dumps it to <sd>/.whole
# (one path per line) and reconciles: a selected path is whole unless .sel names a subset.
#
# Subcommands (all OFF the Tab hot path — drill / preview / finalize only):
#   set  <sd> <path> <spec>   set one path's spec (spec="" clears it)   — child write
#   get  <sd> <path>          print one path's spec                     — child/preview read
#   post <sd> <path>          emit the fzf action for the parent's post-drill transform
#   hint <sd> <path>          print a one-line partial hint for the preview
# git paths never carry a literal tab or newline (core.quotePath), so the
# path/spec line pairs parse unambiguously.
set -u

cmd=${1:-}
sd=${2:-}
[ -n "$sd" ] || exit 1
sel="$sd/.sel"
# Ensure .sel exists so awk never getlines a missing file (keeps stderr clean).
[ -f "$sel" ] || : >"$sel"

# Print the spec stored for the given path (empty if none).
read_spec() {
  awk -v want="$1" -v sel="$sel" '
    BEGIN {
      while ((getline a < sel) > 0) {
        if ((getline b < sel) <= 0) b = ""
        if (a == want) { print b; exit }
      }
    }
  '
}

case "$cmd" in
  get)
    read_spec "${3:-}"
    ;;
  set)
    # Child: set (or, with an empty spec, clear) one path's spec.
    awk -v want="${3:-}" -v spec="${4:-}" -v sel="$sel" '
      BEGIN {
        while ((getline a < sel) > 0) { if ((getline b < sel) <= 0) b = ""; m[a] = b }
        close(sel)
        if (spec == "") delete m[want]; else m[want] = spec
        printf "" >sel
        for (k in m) { print k >sel; print m[k] >sel }
        close(sel)
      }
    '
    ;;
  post)
    # Parent's post-drill transform. The child has just written this path's spec
    # (or cleared it) and, on its own Enter (finalize), left a .execute sentinel.
    #   finalize  -> dump fzf's NATIVE selection ({+f}) into .whole, then commit.
    #                If this path has a spec it is the drill target: select it first
    #                so it joins the selection. Guard on FZF_SELECT_COUNT so an empty
    #                selection stays empty (fzf's {+f} falls back to the current line).
    #   otherwise -> reflect the drilled path's spec as a native select/deselect,
    #                with NO reload — a reload wipes every native mark.
    _post_path=${3:-}
    _post_spec=$(read_spec "$_post_path")
    if [ -e "$sd/.execute" ]; then
      _post_pre=""
      [ -n "$_post_spec" ] && _post_pre="select+"
      # {+f} and $FZF_SELECT_COUNT are deliberately literal: fzf re-expands {+f} in
      # the emitted action, and the become's shell reads FZF_SELECT_COUNT from env.
      # shellcheck disable=SC2016
      printf '%sbecome(if [ "${FZF_SELECT_COUNT:-0}" -gt 0 ]; then cat {+f}; fi >%s/.whole; touch %s/.commit)' \
        "$_post_pre" "$sd" "$sd"
    else
      [ -n "$_post_spec" ] && printf 'select' || printf 'deselect'
    fi
    ;;
  hint)
    # Preview header: whole files (ALL, or natively selected with no spec) need no
    # hint — fzf's own marker shows them. Only a hunk SUBSET gets a line.
    _hint_spec=$(read_spec "${3:-}")
    case "$_hint_spec" in
      "" | ALL) ;;
      *) printf '◐ hunks: %s\n' "$_hint_spec" ;;
    esac
    ;;
  *) exit 0 ;;
esac
