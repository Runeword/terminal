#!/bin/sh
# Toggle-state manager for the __ripgrep gitignore switch (bound to ctrl-g in
# fm.sh). A single per-session state file records whether the interactive rg
# search should descend into VCS-ignored paths:
#   empty/absent -> respect .gitignore (rg default; skips build output, the
#                   dominant cost in large trees)
#   non-empty    -> add --no-ignore-vcs (search gitignored files too)
# Both this manager and the search (fm_rg.sh) read the same file, so the header
# label and the actual rg flags can never disagree.
#
#   fm_rg_ignore.sh flip   <statefile>   # flip the state (no output)
#   fm_rg_ignore.sh header <statefile>   # print the fzf header for the state
sf="$2"
help='fzf-style: '\''exact !not [!]^prefix [!]suffix$ a|b, global smart-case'
case "$1" in
  flip)
    if [ -s "$sf" ]; then : >"$sf"; else printf 1 >"$sf"; fi
    ;;
  header)
    if [ -s "$sf" ]; then g=shown; else g=hidden; fi
    printf '%s   ctrl-g gitignored:%s\n' "$help" "$g"
    ;;
esac
