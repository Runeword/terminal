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
# rg runs --color never; the grouping awk does the highlighting from the spec, so
# every positive term is colored (rg's own match color marks only one span/line).
# Literals highlight wherever they occur, fuzzy terms per matched character (like
# fzf). The spec is tab-separated "TYPE:text" entries (L exact, F fuzzy); CI=1 when
# the search is case-insensitive.
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
# lines don't flood awk/fzf. The wrapper's --ignore-file .config/ignore still
# applies (node_modules, .direnv, .cache, ...), independent of the VCS-ignore flag.
#
# rg runs with --null, so each match is PATH<NUL>LINE:CODE; the grouping awk splits
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
comp=$(fm-query "$1")
regex=$(printf '%s\n' "$comp" | sed -n 1p)
[ -n "$regex" ] || exit 0
spec=$(printf '%s\n' "$comp" | sed -n 2p)
# Smart-case, but global over the whole raw query (any uppercase anywhere makes
# every term case-sensitive), not fzf's per-term rule. Intentional: it keeps rg,
# the list highlight, and the preview in lockstep. See fm-query's header comment.
case "$1" in *[A-Z]*)
  ci=--case-sensitive
  ci01=0
  ;;
*)
  ci=--ignore-case
  ci01=1
  ;;
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
  awk -v HL="$spec" -v CI="$ci01" '
  function hlcode(code,   n,i,cl,m,parts,ent,typ,txt,t,start,k,pos,j,s,ch,res,inrun,ok,cnt,c,seq){
    n=length(code); for(i=1;i<=n;i++) mark[i]=0
    cl = CI ? tolower(code) : code
    m=split(HL, parts, "\t")
    for(i=1;i<=m;i++){ ent=parts[i]; if(ent=="")continue
      typ=substr(ent,1,1); txt=substr(ent,3); t=CI?tolower(txt):txt
      if(typ=="L"){ start=1; while((k=index(substr(cl,start),t))>0){ pos=start+k-1; for(j=pos;j<pos+length(t);j++)mark[j]=1; start=pos+1 } }
      else { ok=1; cnt=0; start=1; for(s=1;s<=length(t);s++){ ch=substr(t,s,1); k=index(substr(cl,start),ch); if(k==0){ok=0;break} pos=start+k-1; seq[++cnt]=pos; start=pos+1 } if(ok)for(c=1;c<=cnt;c++)mark[seq[c]]=1 } }
    res=""; inrun=0
    for(i=1;i<=n;i++){ if(mark[i]&&!inrun){res=res "\033[1;36m"; inrun=1} else if(!mark[i]&&inrun){res=res "\033[0m"; inrun=0} res=res substr(code,i,1) }
    if(inrun)res=res "\033[0m"; return res
  }
  BEGIN { NUL = sprintf("%c", 0) }
  # rg --null emits PATH<NUL>LINE:CODE. Split on the NUL, not the first colon, so a
  # path that itself contains ":" (foo:bar.txt) or "/" is not mis-split. Squash tabs
  # in the path too (code already is) so neither injects extra tab-delimited fields.
  # A record with no NUL is the pre-newline fragment of a filename that contains a
  # newline (rg still ends records with one); drop it rather than emit a phantom row.
  { z=index($0,NUL); if(z==0)next
    path=substr($0,1,z-1); rest=substr($0,z+1); q=index(rest,":"); line=substr(rest,1,q-1); code=substr(rest,q+1)
    gsub(/\t/," ",path); gsub(/\t/," ",code); code=hlcode(code)
    if(path!=cur){cur=path; printf "\033[1;35m%s\033[0m\t%s\t%s\tH\n", path, path, line}
    printf "  %s:%s\t%s\t%s\tM\n", line, code, path, line }
  '
