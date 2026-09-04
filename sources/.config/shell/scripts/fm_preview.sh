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
    # Highlight the query's positive terms in the preview, consistent with the
    # interactive list (fm_rg.sh). fm-query (the shared fzf-query compiler) prints
    # the highlight spec on line 2 as tab-separated TYPE:text entries: L exact,
    # F fuzzy. We hand the raw spec to awk (types intact) so literal terms match as
    # substrings and fuzzy terms match per character (a subsequence, "cfg" in
    # "config"), exactly like fm_rg.sh's list highlighter -- stripping the type,
    # as before, made every fuzzy term match full-word-only. Negated terms aren't
    # in the spec, so they're excluded automatically. Smart-case follows the query
    # (uppercase anywhere -> case-sensitive), matching the list.
    hlspec=""
    if command -v fm-query >/dev/null 2>&1; then
      hlspec=$(fm-query "$3" | sed -n 2p)
    fi
    case "$3" in
      *[A-Z]*) ci01=0 ;;
      *) ci01=1 ;;
    esac

    {
      if [ -n "$2" ]; then
        bat --style=numbers --color=always --highlight-line "$2" "$1"
      else
        bat --style=numbers --color=always "$1"
      fi
    } | {
      if [ -n "$hlspec" ]; then
        # Reverse-video the matched characters. ANSI-aware: bat's color codes are
        # copied verbatim and never matched inside. We split each line into its
        # plain text plus an emit stream, mark which plain-text positions each term
        # covers (L: every substring occurrence; F: the leftmost subsequence, per
        # character), then re-emit with 7m/27m around marked runs so the underlying
        # fg/bg colors are preserved. ON is re-asserted after any escape inside a
        # run so a mid-run reset from bat can't drop the reverse (swap 7m/27m for
        # 4m/24m if you prefer underline).
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
            # 1. Tokenize into plain text (plain) plus an emit stream of escapes (E)
            #    and characters (C, tagged with their plain-text index).
            s = $0; np = 0; nt = 0; plain = ""
            while (length(s) > 0) {
              if (substr(s, 1, 1) == ESC) {
                # ESC-led: emit verbatim as an E token (never plain text, so it
                # neither shifts plain-text indices nor gets marked). A CSI/SGR
                # (incl. private '?' params like \033[?25l) is consumed whole; any
                # other ESC form (OSC \033]…, charset select, bare/trailing ESC)
                # consumes just the ESC byte so the loop always advances -- else
                # seglen stalls at 0 and the tokenizer spins forever (100% CPU,
                # blank preview) on that byte.
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
            # 2. Mark plain-text positions per term. Same subsequence logic as
            #    fm_rg.sh hlcode, but the preview renders every line (not only the
            #    lines that matched the pattern), so a fuzzy term commits its marks
            #    only when the WHOLE subsequence is present -- otherwise a partial
            #    prefix would speckle non-matching lines with stray single chars.
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
            # 3. Re-emit, wrapping marked runs in ON/OFF and passing escapes through.
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
    } | sed 's/^/  /'
  else
    cat "$1"
  fi
fi
