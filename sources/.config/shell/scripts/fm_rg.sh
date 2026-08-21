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
# The grouping awk turns each "path:line:code" match into a tab-delimited row: one
# bold header row per file (its path), then one indented "line:code" row per match.
# fzf shows only field 1 (--with-nth 1); fields 2 and 3 carry the real path and
# line for the preview and open action, and field 4 tags the row H (header) or M
# (match) so __ripgrep's nav binds can skip past the non-selectable headers. Tabs
# in matched code are squashed to spaces so code can't inject extra fields.
[ -n "$1" ] || exit 0
comp=$(fm-query "$1")
regex=$(printf '%s\n' "$comp" | sed -n 1p)
[ -n "$regex" ] || exit 0
spec=$(printf '%s\n' "$comp" | sed -n 2p)
case "$1" in *[A-Z]*)
  ci=--case-sensitive
  ci01=0
  ;;
*)
  ci=--ignore-case
  ci01=1
  ;;
esac
rg -P "$ci" \
  --color never \
  --line-number \
  --no-heading \
  --no-ignore-vcs \
  --max-columns 300 \
  --max-columns-preview \
  -- "$regex" </dev/null 2>/dev/null |
  awk -v HL="$spec" -v CI="$ci01" '
  function hlcode(code,   n,i,cl,m,parts,ent,typ,txt,t,start,k,pos,j,s,ch,res,inrun){
    n=length(code); for(i=1;i<=n;i++) mark[i]=0
    cl = CI ? tolower(code) : code
    m=split(HL, parts, "\t")
    for(i=1;i<=m;i++){ ent=parts[i]; if(ent=="")continue
      typ=substr(ent,1,1); txt=substr(ent,3); t=CI?tolower(txt):txt
      if(typ=="L"){ start=1; while((k=index(substr(cl,start),t))>0){ pos=start+k-1; for(j=pos;j<pos+length(t);j++)mark[j]=1; start=pos+1 } }
      else { start=1; for(s=1;s<=length(t);s++){ ch=substr(t,s,1); k=index(substr(cl,start),ch); if(k==0)break; pos=start+k-1; mark[pos]=1; start=pos+1 } } }
    res=""; inrun=0
    for(i=1;i<=n;i++){ if(mark[i]&&!inrun){res=res "\033[1;36m"; inrun=1} else if(!mark[i]&&inrun){res=res "\033[0m"; inrun=0} res=res substr(code,i,1) }
    if(inrun)res=res "\033[0m"; return res
  }
  { p=index($0,":"); path=substr($0,1,p-1); rest=substr($0,p+1); q=index(rest,":"); line=substr(rest,1,q-1); code=substr(rest,q+1)
    gsub(/\t/," ",code); code=hlcode(code)
    if(path!=cur){cur=path; printf "\033[1;35m%s\033[0m\t%s\t%s\tH\n", path, path, line}
    printf "  %s:%s\t%s\t%s\tM\n", line, code, path, line }
  '
