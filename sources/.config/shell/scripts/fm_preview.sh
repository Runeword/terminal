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

  # Highlight spec for the query's positive terms, shared by both renderers below.
  # fm-query (the shared fzf-query compiler) prints the spec on line 2 as
  # tab-separated TYPE:text entries (L exact, F fuzzy). Negated terms aren't in the
  # spec, so they're excluded automatically. Smart-case follows the query
  # (uppercase anywhere -> case-sensitive), matching the interactive list.
  hlspec=""
  if command -v fm-query >/dev/null 2>&1; then
    hlspec=$(fm-query "$3" | sed -n 2p)
  fi
  case "$3" in
    *[A-Z]*) ci01=0 ;;
    *) ci01=1 ;;
  esac

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

  # Reverse-video the query's positive terms (ANSI-aware). The highlighter's colour
  # codes are copied verbatim and never matched inside; L terms match as substrings,
  # F terms per character (a subsequence). ON is re-asserted after any escape inside
  # a run so a mid-run reset can't drop the reverse. Shared by both renderers.
  termhl() {
    if [ -n "$hlspec" ]; then
      HLSPEC="$hlspec" awk -v CI="$ci01" '
        BEGIN {
          ne = split(ENVIRON["HLSPEC"], E, "\t"); m = 0
          for (i = 1; i <= ne; i++) if (E[i] != "") {
            m++; TYP[m] = substr(E[i], 1, 1)
            t = substr(E[i], 3); TXT[m] = CI ? tolower(t) : t
          }
          ON = "\033[7m"; OFF = "\033[27m"; ESC = "\033"
        }
        m == 0 { print; next }
        {
          s = $0; np = 0; nt = 0; plain = ""
          while (length(s) > 0) {
            if (substr(s, 1, 1) == ESC) {
              if (match(s, /^\033\[[0-9;?]*[A-Za-z]/)) {
                nt++; TT[nt] = "E"; TV[nt] = substr(s, 1, RLENGTH)
                s = substr(s, RLENGTH + 1)
              } else {
                nt++; TT[nt] = "E"; TV[nt] = ESC
                s = substr(s, 2)
              }
              continue
            }
            ei = index(s, ESC); seglen = (ei == 0) ? length(s) : ei - 1
            seg = substr(s, 1, seglen)
            for (j = 1; j <= seglen; j++) {
              np++; ch = substr(seg, j, 1); plain = plain ch
              nt++; TT[nt] = "C"; TV[nt] = ch; TP[nt] = np
            }
            s = substr(s, seglen + 1)
          }
          for (i = 1; i <= np; i++) mark[i] = 0
          cl = CI ? tolower(plain) : plain
          for (i = 1; i <= m; i++) {
            t = TXT[i]; lt = length(t); if (lt == 0) continue
            start = 1
            if (TYP[i] == "L") {
              while ((k = index(substr(cl, start), t)) > 0) {
                pos = start + k - 1
                for (j = pos; j < pos + lt; j++) mark[j] = 1
                start = pos + 1
              }
            } else {
              ok = 1; cnt = 0
              for (c = 1; c <= lt; c++) {
                k = index(substr(cl, start), substr(t, c, 1))
                if (k == 0) { ok = 0; break }
                pos = start + k - 1; cnt++; SEQ[cnt] = pos; start = pos + 1
              }
              if (ok) for (c = 1; c <= cnt; c++) mark[SEQ[c]] = 1
            }
          }
          out = ""; inrun = 0
          for (i = 1; i <= nt; i++) {
            if (TT[i] == "E") {
              out = out TV[i]; if (inrun) out = out ON
            } else {
              p = TP[i]
              if (mark[p] && !inrun) { out = out ON; inrun = 1 }
              else if (!mark[p] && inrun) { out = out OFF; inrun = 0 }
              out = out TV[i]
            }
          }
          if (inrun) out = out OFF
          print out
        }'
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
