#!/bin/sh
# State helper for the two-level files picker (see __git_pick_files in
# .config/shell/functions/git.bash). One fzf shows either the files list or, drilled
# into one file, that file's hunks; `key` and `load` switch between the two in place.
# Whole-file selection is fzf's OWN native multi-select (Tab = select, in-process, no
# subprocess), so this helper is off the Tab hot path. It tracks only DRILLED hunk
# specs, in one file <sd>/.sel, two lines per tracked path: the path, then its spec:
#   ALL          whole file (a drill that kept every hunk)
#   <indices>    space-joined 1-based hunk indices — a partial selection
# A path absent from .sel has no drilled spec (it is whole iff natively selected).
# On finalize <sd>/.whole lists the selected files (one path per line) and the caller
# reconciles: a selected path is whole unless .sel names a subset.
#
# Subcommands (all OFF the Tab hot path — drill / preview / finalize only):
#   set  <sd> <path> <spec>   set one path's spec (spec="" clears it)
#   get  <sd> <path>          print one path's spec                     — preview/finalize read
#   key  <sd> <diff-mode> <key> {+f} {} {+n}
#                             enter/right/left/esc: emit the fzf actions for the key
#   load <sd>                 bound to fzf's load event: finish a list switch
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

# Set (or, with an empty spec, clear) one path's spec.
write_spec() {
  awk -v want="$1" -v spec="$2" -v sel="$sel" '
    BEGIN {
      while ((getline a < sel) > 0) { if ((getline b < sel) <= 0) b = ""; m[a] = b }
      close(sel)
      if (spec == "") delete m[want]; else m[want] = spec
      printf "" >sel
      for (k in m) { print k >sel; print m[k] >sel }
      close(sel)
    }
  '
}

case "$cmd" in
  get)
    read_spec "${3:-}"
    ;;
  set)
    write_spec "${3:-}" "${4:-}"
    ;;
  key)
    # The keys whose meaning depends on the list shown. <sd>/.drill holds the drilled
    # path while the hunks list is up. <diff-mode> (staged|unstaged) picks the diff the
    # hunks come from; {+f} and {+n} are fzf's selection (the focused item when nothing
    # is selected, so FZF_SELECT_COUNT gates them) and {} the focused item.
    #
    # Switching lists is a reload-sync of the other one: it keeps the current list up
    # until the new one is read, and the reload wipes native marks. What must land with
    # the new list (header, marks, cursor, query) is queued in <sd>/.onload for `load`,
    # which fzf runs before it paints the reloaded list, so a switch is one frame. A
    # query change searches again, but a list this small re-filters in well under a
    # millisecond. The switch is committed by `load`, not here: a key pressed before the
    # reload lands still acts on the list on screen.
    _mode=${3:-unstaged} _key=${4:-} _plusf=${5:-} _item=${6:-}
    shift 6 2>/dev/null || set --
    _count=${FZF_SELECT_COUNT:-0}
    if [ -e "$sd/.drill" ]; then
      [ "$_key" = right ] && {
        printf forward-char
        exit 0
      }
      _file=$(cat "$sd/.drill")
      # Record the drilled file's spec WYSIWYG: every hunk -> ALL, a subset -> its
      # 1-based indices ({+n} is 0-based), nothing -> cleared.
      _total=$(grep -c '' "$sd/.hunks")
      if [ "$_count" -eq 0 ]; then
        _spec=""
      elif [ "$_count" -ge "$_total" ]; then
        _spec=ALL
      else
        _spec=$(for _i in "$@"; do echo $((_i + 1)); done | sort -n | tr '\n' ' ')
        _spec=${_spec% }
      fi
      write_spec "$_file" "$_spec"
      # The files marked before the drill, with the drilled file in or out by its spec.
      _marked=$(
        grep -vxF -- "$_file" "$sd/.marks"
        [ -z "$_spec" ] || printf '%s\n' "$_file"
      )
      if [ "$_key" = enter ]; then
        printf '%s\n' "$_marked" | grep . >"$sd/.whole"
        : >"$sd/.commit"
        printf accept
        exit 0
      fi
      # Left / Esc: back to the files list. Marks are restored by position with the
      # query empty (every file listed, in input order), then the saved query comes
      # back with the cursor tracking the drilled file.
      _pos=$(printf '%s\n' "$_marked" | awk 'NR == FNR { want[$0]; next } $0 in want { printf "pos(%d)+select+", FNR }' - "$sd/.files")
      _at=$(awk -v want="$_file" '$0 == want { print NR; exit }' "$sd/.files")
      _clear=""
      [ -z "${FZF_QUERY:-}" ] || _clear="change-query()+wait+"
      _query=""
      [ ! -s "$sd/.query" ] || _query="+track-current+transform-query(cat $sd/.query)+wait+untrack-current"
      printf 'change-header(%s)+%s%spos(%s)%s' "${GFS_HEADER_FILES:-}" "$_clear" "$_pos" "$_at" "$_query" >"$sd/.onload"
      : >"$sd/.to-files"
      printf 'reload-sync(cat %s/.files)' "$sd"
      exit 0
    fi
    case "$_key" in
      left) printf backward-char ;;
      esc)
        # The global esc (FZF_DEFAULT_OPTS): abort from search mode; from nav mode, back
        # to search, the toggle alt-i is bound to.
        if [ "${FZF_INPUT_STATE:-enabled}" = enabled ]; then
          printf abort
        else
          printf 'trigger(alt-i)'
        fi
        ;;
      enter | right)
        [ -n "$_item" ] || exit 0
        case "$_mode" in
          staged) _diff=$(git diff --cached --unified=0 -- "$_item") ;;
          *) _diff=$(git diff --unified=0 -- "$_item") ;;
        esac
        if [ -z "$_diff" ]; then
          # No hunks (untracked / unchanged): Enter finalizes the selection as it
          # stands (such a file counts only if Tab-marked); Right is a no-op.
          if [ "$_key" = enter ]; then
            if [ "$_count" -gt 0 ]; then cat "$_plusf"; fi >"$sd/.whole"
            : >"$sd/.commit"
            printf accept
          fi
          exit 0
        fi
        # Drill. Save what the files list will need back (marks, query), list the
        # hunks, and queue their preselection: the saved spec, or every hunk for a
        # Tab-marked file with none (so a drill can't silently drop it).
        printf '%s\n' "$_diff" >"$sd/.diff"
        git-hunk-pick list <"$sd/.diff" | cut -f2- >"$sd/.hunks"
        if [ "$_count" -gt 0 ]; then cat "$_plusf"; fi >"$sd/.marks"
        printf '%s' "${FZF_QUERY:-}" >"$sd/.query"
        _spec=$(read_spec "$_item")
        if [ -z "$_spec" ] && grep -qxF -- "$_item" "$sd/.marks"; then
          _spec=ALL
        fi
        _pre=""
        if [ "$_spec" = ALL ]; then
          _pre="select-all+"
        elif [ -n "$_spec" ]; then
          for _i in $_spec; do _pre="${_pre}pos($_i)+select+"; done
        fi
        _clear=""
        [ -z "${FZF_QUERY:-}" ] || _clear="change-query()+wait+"
        printf 'change-header(%s)+%s%sfirst' "${GFS_HEADER_HUNKS:-}" "$_clear" "$_pre" >"$sd/.onload"
        printf '%s\n' "$_item" >"$sd/.to-hunks"
        printf 'reload-sync(cat %s/.hunks)' "$sd"
        ;;
    esac
    ;;
  load)
    # fzf's load event, after every reload-sync (and the initial read): commit the
    # switch `key` requested and emit what it queued for this moment.
    if [ -e "$sd/.to-hunks" ]; then
      mv "$sd/.to-hunks" "$sd/.drill"
    elif [ -e "$sd/.to-files" ]; then
      rm -f "$sd/.to-files" "$sd/.drill"
    fi
    if [ -e "$sd/.onload" ]; then
      cat "$sd/.onload"
      rm -f "$sd/.onload"
    fi
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
