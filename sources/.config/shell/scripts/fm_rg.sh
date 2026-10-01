#!/bin/sh
# Stream ripgrep matches for the __ripgrep fzf binding (interactive search).
# $1 is the fzf-style query. fm-query compiles it into (1) a PCRE2 filter regex and
# (2) a highlight spec. Syntax: spaces separate AND terms; a bare term is fuzzy
# ("cfg" matches "config"); 'term is an exact substring; ^term / term$ anchor to
# line start/end; !term excludes; a lone | ORs the terms on either side of it
# ("go$ | rb$" matches lines ending in go OR rb); a backslash escapes a space, so
# "foo\ bar" is one term with a literal space, not two. Each AND term (or a
# |-joined OR group) becomes a lookahead so they combine on one line (rg -P); case
# follows the query (smart-case). An empty query, or one with only
# exclusions, yields no output, so fzf starts empty instead of dumping the tree.
#
# rg runs --color never; `fm-query rows` does the highlighting, so every positive
# term is colored (rg's own match color marks only one span/line). Literals
# highlight wherever they occur, fuzzy terms per matched character (like fzf).
#
# rg reads stdin (blocking) when given no path and a non-tty stdin, so stdin is
# pinned to /dev/null -- rg then searches the working directory and still prints
# bare paths (an explicit "." would prefix every path with "./"). stderr is
# dropped so an in-progress regex (e.g. a lone "[") doesn't flash while typing.
#
# rg respects .gitignore here (no --no-ignore-vcs), so the walk skips gitignored
# build output (target/, dist/, .venv, ...) -- the dominant cost in large trees.
# --max-columns caps how much of a matching line is emitted; --max-columns-preview
# keeps a truncated snippet instead of an omission note, so minified/generated
# lines don't flood fzf. The wrapper's --ignore-file .config/ignore still
# applies (node_modules, .direnv, .cache, ...), independent of the VCS-ignore flag.
#
# rg runs with --null, so each match is PATH<NUL>LINE:CODE; `fm-query rows` splits
# on that NUL (not the first colon) into path + line:code, so a path that itself
# contains ":" or "/" is not mangled. It turns each match into a tab-delimited row:
# one bold header row per file (its path), then one indented "line:code" row per
# match. fzf shows only field 1 (--with-nth 1); fields 2 and 3 carry the real path
# and line for the preview and open action, and field 4 tags the row H (header) or M
# (match) so __ripgrep's nav binds can skip past the non-selectable headers. Tabs in
# the path and in matched code are squashed to spaces so neither can inject extra
# tab-delimited fields.
[ -n "$1" ] || exit 0
# Unlike the preview (where a missing fm-query only drops highlighting), fm-query
# is essential here: it compiles the regex. If it is absent (a degraded env -- the
# wrapper normally puts it on PATH), show a row rather than a silent empty list,
# which would be indistinguishable from "no matches".
command -v fm-query >/dev/null 2>&1 || {
  printf 'fm-query not found on PATH -- interactive search unavailable\n'
  exit 0
}
regex=$(fm-query "$1" | sed -n 1p)
[ -n "$regex" ] || exit 0
# Smart-case, but global over the whole raw query (any uppercase anywhere makes
# every term case-sensitive), not fzf's per-term rule. Intentional: it keeps rg,
# the list highlight, and the preview in lockstep. See fm-query's header comment.
case "$1" in
  *[A-Z]*) ci=--case-sensitive ;;
  *) ci=--ignore-case ;;
esac
# $2 (optional) is the gitignore-toggle state file written by fm_rg_ignore.sh
# (bound to ctrl-g in fm.sh): non-empty => also search VCS-ignored files
# (--no-ignore-vcs, e.g. build output); empty/absent => respect .gitignore,
# the default fast path. Reading it here (and in the header) keeps flag and
# label in sync.
vcs=
[ -n "${2:-}" ] && [ -s "$2" ] && vcs=--no-ignore-vcs
# shellcheck disable=SC2086  # $vcs is empty or exactly one flag; split intended
rg -P "$ci" \
  $vcs \
  --color never \
  --line-number \
  --no-heading \
  --null \
  --max-columns 300 \
  --max-columns-preview \
  -- "$regex" </dev/null 2>/dev/null |
  fm-query rows "$1"
