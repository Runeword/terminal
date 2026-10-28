#!/bin/sh

# fzf runs the preview with an empty slot when the result list is empty (e.g. an
# interactive rg search before you type). Bail out quietly unless $1 is a regular
# file or a directory: sed would read a device like /dev/zero forever (one
# endless line) and block on a FIFO.
[ -f "$1" ] || [ -d "$1" ] || exit 0

w=${FZF_PREVIEW_COLUMNS:-100}
case "$w" in '' | *[!0-9]*) w=100 ;; esac
[ "$w" -ge 1 ] || w=100

if [ -d "$1" ]; then
  # if command -v exa >/dev/null; then
  #   exa "$1" --long --octal-permissions --color=always --list-dirs --total-size |
  #     sed 's/^/  /; 1s/^/\n/'
  # else
  #   ls -ld "$1"
  # fi

  # tree -Ca -L 2 "$1" | sed 's/^/  /; 1s/^/\n/'
  # -- so a repo entry named like an option (e.g. --help.txt) is treated as a path;
  # -q prints a control character in a name as ?, so none reaches fzf.
  command ls -C --almost-all --color -q --width "$w" -- "$1"
else
  # printf, not echo: a path beginning with -n/-e/-E would be swallowed as a flag.
  # tr drops control characters, a newline included, so the name can neither
  # carry an escape sequence to fzf nor push the ~2 header down.
  printf '%s' "$1" | tr -d '\001-\037\177'
  printf '\n\n'

  matchline="$2"
  query="$3"
  # Digits only: anything else is ignored rather than handed to shell arithmetic.
  case "$matchline" in *[!0-9]*) matchline= ;; esac

  # Window around the match: as many lines as the preview shows below its two
  # header lines, with the match centred; fm.sh scrolls the preview to the top
  # (~2, no +{3} offset), so the leading lines position the match. Near the top
  # of the file the window starts at line 1 and still fills the preview.
  # FZF_PREVIEW_LINES is the preview height. Without a match line ($2 empty -- the
  # file-browser preview from __open_file) show the head of the file.
  h=${FZF_PREVIEW_LINES:-40}
  case "$h" in '' | *[!0-9]*) h=40 ;; esac
  [ "$h" -ge 1 ] || h=40
  rows=$((h - 2))
  [ "$rows" -ge 1 ] || rows=1
  start=1
  [ -n "$matchline" ] && start=$((matchline - (rows - 1) / 2))
  [ "$start" -lt 1 ] && start=1
  end=$((start + rows - 1))

  # The highlighters see up to 300 lines before the window and 100 after it, so a
  # window that opens or ends inside a block comment, a string or a heredoc is
  # coloured as in the whole file; the gutter drops those lines again. (Nix, the
  # slowest grammar here, highlights ~8 lines/ms.)
  ctx=$((start - 300))
  [ "$ctx" -lt 1 ] && ctx=1
  skip=$((start - ctx))
  lend=$((end + 100))

  # What the highlighters see: lines ctx..lend, each cut to twice what the preview
  # shows (a minified line would otherwise be highlighted, marked and handed to
  # fzf whole), without control characters, so no escape sequence in the file (an
  # OSC 8 link, say) reaches fzf. CR goes too, so a CRLF file shows like any other.
  clip=$((w * 2))
  slice() {
    sed -n "${ctx},${lend}p;${lend}q" -- "$1" | tr -d '\000-\010\013-\037\177' | cut -c "1-$clip"
  }

  # The tree-sitter scope for an extensionless script's #! interpreter: its
  # highlight command picks a grammar only by file name (or --scope).
  shebang_scope() {
    case "${1##*/}" in *.*) return ;; esac
    first=$(head -c 256 -- "$1" | tr -d '\000')
    case "$first" in '#!'*) ;; *) return ;; esac
    first=${first#??}
    first=${first%%"
"*}
    set -f
    # shellcheck disable=SC2086 # the #! line's words
    set -- $first
    set +f
    case "${1##*/}" in env) shift ;; esac
    [ "${1:-}" = -S ] && shift
    case "${1##*/}" in
      sh | ash | bash | dash | ksh | mksh | zsh) echo source.bash ;;
      python*) echo source.python ;;
      node | nodejs) echo source.js ;;
    esac
  }

  # Reverse-video the query's positive terms with the interactive list's matcher
  # (fm-query, the shared fzf-query compiler; smart-case follows the query, negated
  # terms stay unmarked). ANSI-aware: the highlighter's colour codes are copied
  # verbatim and never matched inside, and the reverse is re-asserted after one
  # inside a run. Without fm-query the preview only loses this marking. Shared by
  # every renderer.
  termhl() {
    if command -v fm-query >/dev/null 2>&1; then
      fm-query mark "$query"
    else
      cat
    fi
  }

  # Left gutter of real line numbers; the match line's number is reverse-video.
  # Runs AFTER termhl so a numeric query term never marks the gutter digits. It
  # drops the context lines around the window, and carries the colour a
  # highlighter left open across lines: tree-sitter colours a multi-line token
  # once, and the number's reset would otherwise end it after its first line.
  gutter() {
    awk -v start="$start" -v end="$end" -v mline="${matchline:-0}" -v skip="$skip" '
      BEGIN { w = length(end ""); if (w < 3) w = 3 }
      NR > skip {
        n = start + NR - skip - 1
        if (n > end) exit
        if (n == mline) printf "  \033[7m%*d\033[0m %s%s\n", w, n, open, $0
        else printf "  \033[38;2;75;88;110m%*d\033[0m %s%s\n", w, n, open, $0
      }
      {
        s = $0
        while (match(s, /\033\[[0-9;:]*m/)) {
          e = substr(s, RSTART, RLENGTH)
          s = substr(s, RSTART + RLENGTH)
          if (e == "\033[0m" || e == "\033[m") open = ""
          else if (e ~ /^\033\[0;/) open = e
          else if (e != "\033[7m" && e != "\033[27m") open = open e
        }
      }'
  }

  # Primary renderer: tree-sitter structural highlight. tree-sitter has no
  # line-range flag, so it gets the slice as a file that keeps the original
  # basename, in a temp dir, so language detection -- by extension OR full name
  # (Makefile, go.mod, .zshrc) -- still fires. It runs from that dir, as it also
  # loads a grammar it finds in its working directory, and the slice sits one
  # level down: a previewed tree-sitter.json in the working directory would be
  # read as a grammar's, whose paths tree-sitter compiles and loads. Empty
  # output => no grammar for this file type; fall back to bat below. fzf
  # SIGKILLs a preview it no longer shows, so the rm below may never run: the
  # temp dir goes in the per-session dir the caller removes after fzf
  # ($FM_SESSION_DIR), else in the per-user runtime dir (the claude sandbox
  # shares /tmp, while it has a private $XDG_RUNTIME_DIR).
  base=${1##*/}
  ts_out=""
  if command -v tree-sitter >/dev/null 2>&1 &&
    tsdir=$(mktemp -d "${FM_SESSION_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}/fm_ts.XXXXXX" 2>/dev/null); then
    scope=$(shebang_scope "$1")
    mkdir "$tsdir/f" && slice "$1" >"$tsdir/f/$base" &&
      ts_out=$(cd "$tsdir" && tree-sitter highlight -q ${scope:+--scope "$scope"} "f/$base" 2>/dev/null)
    rm -rf "$tsdir"
  fi

  if [ -n "$ts_out" ]; then
    printf '%s\n' "$ts_out"
  elif command -v bat >/dev/null 2>&1; then
    # Fallback for file types tree-sitter has no grammar for: bat (syntect), which
    # picks its syntax by the file name. Plain style: the gutter numbers the lines.
    slice "$1" | bat --color=always --style=plain --paging=never --file-name "$base"
  else
    slice "$1"
  fi | termhl | gutter
fi
