#!/bin/sh

# fzf runs the preview with an empty slot when the result list is empty (e.g. an
# interactive rg search before you type). Bail out quietly unless $1 is a path.
[ -e "$1" ] || exit 0

if [ -d "$1" ]; then
  # if command -v exa >/dev/null; then
  #   exa "$1" --long --octal-permissions --color=always --list-dirs --total-size |
  #     sed 's/^/  /; 1s/^/\n/'
  # else
  #   ls -ld "$1"
  # fi

  # tree -Ca -L 2 "$1" | sed 's/^/  /; 1s/^/\n/'
  # -- so a repo entry named like an option (e.g. --help.txt) is treated as a path.
  command ls -C --almost-all --color --width 90 -- "$1"
else
  # printf, not echo: a path beginning with -n/-e/-E would be swallowed as a flag.
  printf '%s\n' "$1"
  echo ""

  matchline="$2"
  query="$3"

  # Window around the match. Show ~half the preview's content height of context
  # above the match so it lands centred; fm.sh scrolls the preview to the top
  # (~2, no +{3} offset), so these leading lines position the match.
  # FZF_PREVIEW_LINES is the preview height. Without a match line ($2 empty -- the
  # file-browser preview from __open_file) show the head of the file.
  h=${FZF_PREVIEW_LINES:-40}
  case "$h" in '' | *[!0-9]*) h=40 ;; esac
  [ "$h" -ge 1 ] || h=40
  above=$(((h - 2) / 2))
  if [ -n "$matchline" ]; then
    start=$((matchline - above))
    [ "$start" -lt 1 ] && start=1
    end=$((matchline + above))
  else
    start=1
    end=$h
  fi

  # Reverse-video the query's positive terms with the interactive list's matcher
  # (fm-query, the shared fzf-query compiler; smart-case follows the query, negated
  # terms stay unmarked). ANSI-aware: the highlighter's colour codes are copied
  # verbatim and never matched inside, and the reverse is re-asserted after one
  # inside a run. Without fm-query the preview only loses this marking. Shared by
  # both renderers.
  termhl() {
    if command -v fm-query >/dev/null 2>&1; then
      fm-query mark "$query"
    else
      cat
    fi
  }

  # Left gutter of real line numbers; the match line's number is reverse-video.
  # Runs AFTER termhl so a numeric query term never marks the gutter digits.
  gutter() {
    awk -v start="$start" -v end="$end" -v mline="${matchline:-0}" '
      BEGIN { w = length(end ""); if (w < 3) w = 3 }
      { n = start + NR - 1
        if (n == mline) printf "\033[7m%*d\033[0m %s\n", w, n, $0
        else printf "\033[38;2;75;88;110m%*d\033[0m %s\n", w, n, $0 }'
  }

  # Primary renderer: tree-sitter structural highlight of the windowed slice.
  # tree-sitter has no line-range flag, so slice first -- this also keeps the
  # O(lines) termhl above cheap on huge files, exactly as the old bat --line-range
  # did. The slice keeps the original basename in a temp dir so language detection
  # -- by extension OR full name (Makefile, go.mod, .gitignore) -- still fires.
  # Empty output => no grammar for this file type; fall back to bat below.
  ts_out=""
  if command -v tree-sitter >/dev/null 2>&1; then
    tsdir=$(mktemp -d "${TMPDIR:-/tmp}/fm_ts.XXXXXX")
    tsf="$tsdir/$(basename -- "$1")"
    sed -n "${start},${end}p" -- "$1" >"$tsf" 2>/dev/null
    ts_out=$(tree-sitter highlight -q "$tsf" 2>/dev/null)
    rm -rf "$tsdir"
  fi

  if [ -n "$ts_out" ]; then
    printf '%s\n' "$ts_out" | termhl | gutter | sed 's/^/  /'
  elif command -v bat >/dev/null 2>&1; then
    # Fallback for file types tree-sitter has no grammar for: bat (syntect) still
    # windows, numbers and highlights the match line here.
    {
      if [ -n "$matchline" ]; then
        bat --style=numbers --color=always --highlight-line "$matchline" \
          --line-range "$start:$end" -- "$1"
      else
        bat --style=numbers --color=always -- "$1"
      fi
    } | termhl | sed 's/^/  /'
  else
    cat -- "$1"
  fi
fi
