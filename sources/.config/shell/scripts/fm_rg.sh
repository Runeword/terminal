#!/bin/sh
# Stream ripgrep matches for the __ripgrep fzf binding (interactive search).
# $1 is the fzf query, used as the rg pattern (regex, smart-case). An empty
# query yields no output, so fzf starts empty instead of dumping the whole tree.
# Each match is reshaped into a two-line fzf item -- "path:line:" then the code,
# split at the second colon and NUL-delimited for `fzf --read0`.
#
# rg reads stdin (blocking) when given no path and a non-tty stdin, so stdin is
# pinned to /dev/null -- rg then searches the working directory and still prints
# bare paths (an explicit "." would prefix every path with "./"). stderr is
# dropped so an in-progress regex (e.g. a lone "[") doesn't flash while typing.
[ -n "$1" ] || exit 0
rg \
  --color always \
  --colors 'path:none' \
  --colors 'line:none' \
  --colors 'line:fg:red' \
  --colors 'match:fg:cyan' \
  --line-number \
  --no-heading \
  --smart-case \
  --no-ignore-vcs \
  -- "$1" </dev/null 2>/dev/null |
  awk '{ p = index($0, ":"); r = substr($0, p + 1); q = index(r, ":"); if (q == 0) printf "%s%c", $0, 0; else printf "%s%s\n%s%c", substr($0, 1, p), substr(r, 1, q), substr(r, q + 1), 0 }'
