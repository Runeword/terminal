#!/bin/sh
# claude's PostToolUse hook on Edit and Write (settings.json): formats the file
# the tool just wrote.
#
# In the session's own repository, when its lefthook config defines formatters
# (the pre-commit jobs that set stage_fixed), those run instead of the built-in
# ones below, and only those: each on this one file, through its own glob, so
# the file comes out the way a commit would leave it, and a file type the
# repository doesn't format stays as it is. Everywhere else, and in a
# repository whose config defines no formatter, the built-in ones run.
#
# Only the session's own repository, whose lefthook config the sandbox keeps
# read-only (claude-sandbox pins each config file that exists; a local config a
# session adds where there was none runs here, as it would at the next commit).
# Elsewhere the config could be one the session wrote, which this hook would
# then run for it, unreviewed. --no-stage-fixed keeps lefthook from staging the
# fix, and from setting aside the unstaged changes of partially staged files
# while the formatter runs, which it only does to stage a fix.
file=$(jq -r '.tool_input.file_path // empty')
[ -f "$file" ] || exit 0
dir=$(dirname -- "$file")
selectors=

# The formatters in the config lefthook merges: a first line saying there are
# some, then a selector for each one lefthook can pick out by name.
formatters='."pre-commit" // {}
  | [(.jobs // [] | .. | objects | select(.stage_fixed == true and (has("run") or has("script")))
      | if (.name // "") != "" then "--job=" + .name else "" end),
    (.commands // {} | to_entries[] | select(.value.stage_fixed == true) | "--command=" + .key),
    (.scripts // {} | to_entries[] | select(.value.stage_fixed == true) | "")]
  | if length > 0 then "formatters", (.[] | select(. != "")) else empty end'

top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ] && [ "$top" = "$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null)" ]; then
  selectors=$(cd "$top" && lefthook dump --format json 2>/dev/null | jq -r "$formatters" 2>/dev/null)
fi

if [ -n "$selectors" ]; then
  set --
  while IFS= read -r selector; do
    [ "$selector" = formatters ] || set -- "$@" "$selector"
  done <<EOF
$selectors
EOF
  # Formatters, but none lefthook can pick out: the file stays as it is.
  [ $# -gt 0 ] || exit 0
  relpath=$(git -C "$dir" rev-parse --show-prefix)${file##*/}
  out=$(cd "$top" && LEFTHOOK_OUTPUT=execution_out,failure lefthook run pre-commit \
    --no-stage-fixed --no-auto-install --no-tty --colors off "$@" --file "$relpath" 2>&1 </dev/null) && exit 0
  rc=$?
  case $out in
    # No formatter's glob takes this file.
    *"no job matching"*) exit 0 ;;
  esac
  printf '%s\n' "$out" >&2
  exit "$rc"
fi

case "$file" in
  *.go) gofmt -w "$file" ;;
  *.nix) nixfmt "$file" ;;
  *.sh) shfmt -w "$file" ;;
  *.toml) taplo fmt "$file" ;;
esac
