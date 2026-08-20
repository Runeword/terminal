#!/bin/sh

# fzf runs the preview with an empty slot when the result list is empty (e.g. an
# interactive rg search before you type). bat errors on an empty/absent FILE, so
# bail out quietly unless $1 is an existing path.
[ -e "$1" ] || exit 0

if [ -d "$1" ]; then
  # if command -v exa >/dev/null; then
  #   exa "$1" --long --octal-permissions --color=always --list-dirs --total-size |
  #     sed 's/^/  /; 1s/^/\n/'
  # else
  #   ls -ld "$1"
  # fi

  # tree -Ca -L 2 "$1" | sed 's/^/  /; 1s/^/\n/'
  command ls -C --almost-all --color --width 90 "$1"
else
  # if command -v exa >/dev/null; then
  #   exa "$1" --long --octal-permissions --color=always |
  #     sed 's/^/  /; 1s/^/\n/'
  # else
  #   ls -l "$1"
  # fi

  echo "$1"
  echo ""
  if command -v bat >/dev/null; then
    # Collect literal terms from the fzf query ($3) to emphasize in the preview.
    # $3 is space-separated AND-terms with optional extended-search operators:
    # drop negations (!term), strip the exact ('), prefix (^) and suffix ($)
    # markers, keep the literal. `set -f` stops a query like *.c from being
    # glob-expanded during the word-split.
    hlterms=""
    if command -v awk >/dev/null 2>&1; then
      set -f
      for w in $3; do
        case $w in
          '!'*) continue ;;
          '|') continue ;;
        esac
        w=${w#\'}
        w=${w#^}
        w=${w%\$}
        [ -n "$w" ] && hlterms="$hlterms$w
"
      done
      set +f
    fi

    {
      if [ -n "$2" ]; then
        bat --style=numbers --color=always --highlight-line "$2" "$1"
      else
        bat --style=numbers --color=always "$1"
      fi
    } | {
      if [ -n "$hlterms" ]; then
        # Reverse-video each term wherever it appears. ANSI-aware: bat's color
        # codes are copied verbatim and never matched inside. Uses the 7m/27m
        # attribute toggle so the underlying fg/bg colors are preserved (swap
        # for 4m/24m if you prefer underline).
        HLTERMS="$hlterms" awk '
          BEGIN {
            nt = split(ENVIRON["HLTERMS"], A, "\n"); m = 0
            for (i = 1; i <= nt; i++) if (A[i] != "") { m++; T[m] = A[i]; L[m] = tolower(A[i]) }
            ON = "\033[7m"; OFF = "\033[27m"; ESC = "\033"
          }
          {
            s = $0; out = ""
            while (length(s) > 0) {
              if (substr(s, 1, 1) == ESC && match(s, /^\033\[[0-9;]*[A-Za-z]/)) {
                out = out substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1); continue
              }
              ei = index(s, ESC); seglen = (ei == 0) ? length(s) : ei - 1
              seg = substr(s, 1, seglen); lseg = tolower(seg)
              bp = 0; bl = 0
              for (i = 1; i <= m; i++) {
                p = index(lseg, L[i])
                if (p > 0 && (bp == 0 || p < bp)) { bp = p; bl = length(T[i]) }
              }
              if (bp > 0) {
                out = out substr(seg, 1, bp - 1) ON substr(seg, bp, bl) OFF
                s = substr(s, bp + bl)
              } else {
                out = out seg; s = substr(s, seglen + 1)
              }
            }
            print out
          }'
      else
        cat
      fi
    } | sed 's/^/  /'
  else
    cat "$1"
  fi
fi
