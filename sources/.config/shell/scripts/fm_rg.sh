#!/bin/sh
# Stream ripgrep matches for the __ripgrep fzf binding (interactive search).
# $1 is the query, in fzf's extended-search syntax, matched as fzf matches it
# (see fm-query's header): spaces separate AND terms; a bare term is fuzzy
# ("cfg" matches "config"); 'term is an exact substring and 'term' an exact
# word; ^term / term$ anchor to line start/end, past surrounding whitespace;
# !term excludes; a lone | ORs the terms on either side of it; a backslash
# escapes a space. Case follows the query as a whole (global smart-case). An
# empty query, or one with only exclusions, yields no output, so fzf starts
# empty instead of dumping the tree.
#
# rg only narrows the search: `fm-query prefilter` gives it one condition
# every matching line meets, which its linear-time engine finds fast, and
# `fm-query rows` applies the whole query and turns each match into a row --
# so no regex engine limit can drop a file. rg runs case-insensitively and
# with --color never; rows decides case and does the highlighting. rows reads
# a line's first 64 KiB only, so a minified file's huge line costs no more than
# a short one.
#
# rg reads stdin (blocking) when given no path and a non-tty stdin, so stdin is
# pinned to /dev/null -- rg then searches the working directory and still prints
# bare paths (an explicit "." would prefix every path with "./"). stderr is
# dropped so an unreadable directory doesn't flash while typing.
#
# --hidden searches dotfiles as __open_file's fd does; the wrapper's --ignore-file
# .config/ignore (.git, node_modules, .direnv, .cache, ...) and .gitignore still
# prune the walk, the latter being the dominant cost in large trees (build
# output: target/, dist/, .venv, ...). The globs skip .git, which a plain rg
# (a devShell's, first on PATH) has no ignore file for, and names holding a
# newline, whose matches rg would print under a fragment of the name. In $HOME,
# fm_home.ignore also skips its own big trees (caches, browser profiles, Go's
# module cache): rg anchors an --ignore-file's patterns at its working
# directory, so anywhere else they would hide a project's own go/pkg or .local.
#
# rg runs with --null, so each match is PATH<NUL>LINE:CODE; `fm-query rows` splits
# on that NUL (not the first colon), so a path that itself contains ":" or "/" is
# not mangled. It turns each match into a tab-delimited row: one bold header row
# per file (its path), then one indented "line:code" row per match. fzf shows only
# field 1 (--with-nth 1); fields 2 and 3 carry the real path and line for the
# preview and open action, and field 4 tags the row H (header) or M (match) so
# __ripgrep can skip past the non-selectable headers.
[ -n "$1" ] || exit 0
# Unlike the preview (where a missing fm-query only drops highlighting), fm-query
# is essential here: it does the matching. If it is absent (a degraded env -- the
# wrapper normally puts it on PATH), show a row rather than a silent empty list,
# which would be indistinguishable from "no matches".
command -v fm-query >/dev/null 2>&1 || {
  printf 'fm-query not found on PATH -- interactive search unavailable\n'
  exit 0
}
# $2 (optional) is the gitignore-toggle state file written by fm_rg_ignore.sh
# (bound to ctrl-g in fm.sh): non-empty => also search VCS-ignored files
# (--no-ignore-vcs, e.g. build output); empty/absent => respect .gitignore,
# the default fast path. Reading it here (and in the header) keeps flag and
# label in sync.
vcs=
[ -n "${2:-}" ] && [ -s "$2" ] && vcs=--no-ignore-vcs
home=
[ "$PWD" = "$HOME" ] && home=$(dirname -- "$0")/fm_home.ignore
nl='
'
if regex=$(fm-query prefilter "$1" 2>/dev/null); then
  [ -n "$regex" ] || exit 0
  # shellcheck disable=SC2086  # $vcs is empty or exactly one flag; split intended
  rg --ignore-case \
    $vcs \
    ${home:+--ignore-file "$home"} \
    --hidden \
    --glob '!.git' \
    --glob "!*$nl*" \
    --color never \
    --line-number \
    --no-heading \
    --null \
    -e "$regex" </dev/null 2>/dev/null |
    fm-query rows "$1"
  exit 0
fi
# An fm-query older than this script has no prefilter: a terminal opened before
# the rebuild that brought it still has the old one on PATH. Its one-argument
# form compiles the query into a PCRE2 pattern instead.
regex=$(fm-query "$1" | sed -n 1p)
[ -n "$regex" ] || exit 0
case "$1" in
  *[A-Z]*) ci=--case-sensitive ;;
  *) ci=--ignore-case ;;
esac
# shellcheck disable=SC2086  # $vcs is empty or exactly one flag; split intended
rg -P "$ci" \
  $vcs \
  ${home:+--ignore-file "$home"} \
  --hidden \
  --glob '!.git' \
  --glob "!*$nl*" \
  --color never \
  --line-number \
  --no-heading \
  --null \
  --max-columns 300 \
  --max-columns-preview \
  -- "$regex" </dev/null 2>/dev/null |
  fm-query rows "$1"
