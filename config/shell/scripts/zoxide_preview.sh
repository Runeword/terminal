#!/bin/sh
# zoxide fzf preview: ANSI-aware, height-first directory listing.

path=$1
[ "$path" != "" ] || exit 0

L="${FZF_PREVIEW_LINES:-20}"

command ls -1p --color=always --group-directories-first "$path" 2>/dev/null |
  awk -v L="$L" '
    { a[NR] = $0 }
    END {
      if (NR == 0) exit
      cols = int((NR + L - 1) / L)
      for (r = 1; r <= L; r++) {
        line = ""
        for (c = 0; c < cols; c++) {
          idx = c * L + r
          if (idx > NR) break
          if (c > 0) line = line "\t"
          line = line a[idx]
        }
        print line
      }
    }
  ' |
  column -t -s "$(printf '\t')" -o '  '
