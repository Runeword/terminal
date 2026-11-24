# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# git.bash: the git pickers (ga, gl, gda/gdc/gdd, grs), on real repos where
# it matters, gpn, and gg, gu and guc.

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# The untracked-file preview hands git diff its path after --: git obeys
# an option even after its paths, so an untracked --output=flake.nix
# would truncate flake.nix just by being shown.
untracked='. @zsh@/.config/shell/functions/git.bash
  git() { pwd; }
  __git_diff_untracked'
case "$(@zsh@/bin/zsh -f -c "$untracked")" in
  *"--no-index --color=always -- /dev/null {} "*) ok "the untracked-file preview hands git diff its path after --" ;;
  *) fail "the untracked-file preview hands git diff its path where an option goes" ;;
esac

# ga (__git_pick_files) shows its files and hunks lists without a
# header: fzf gets no --header, nor a GFS_HEADER_FILES or
# GFS_HEADER_HUNKS for git-hunk-pick, which its binds run, to change
# the header to on each switch. The picker's stdout goes nowhere, so
# the stand-in fzf says what it was handed on stderr.
ga='. @zsh@/.config/shell/functions/git.bash
  git() { :; }; git-hunk-pick() { :; }
  fzf() { printf "%s\n" "$GFS_HEADER_FILES$GFS_HEADER_HUNKS $*" >&2; }
  __git_add'
case "$(@zsh@/bin/zsh -f -c "$ga" 2>&1)" in
  *"--header="* | *"--header "*) fail "ga shows its files or hunks list under a header" ;;
  " "*"--read0 --print0"*) ok "ga shows its files and hunks lists without a header" ;;
  *) fail "ga shows its files or hunks list under a header" ;;
esac

# gl (__git_log), on a real repo through the real git-hunk-pick and
# fzf (log-rows lays the rows out; its own tests cover how): each row
# is as wide as fzf's list, COLUMNS - 3, shown as fzf shows it
# ({1} {6}{3}{4}{2}), numbered from 1 for the newest, right-aligned to
# the 10 commits' two digits. The newest, two minutes old, only
# deletes files: - in bold red, the verb it stands for (Delete)
# dropped, and how long ago it was made in place of its date and time;
# the oldest only adds one: + in bold green, its date and time; an
# empty commit has no change. The search finds a commit by its
# subject, past its number, and fzf hands on its hash; the file step
# lists the commit's files as tree rows, and tree-quote turns the row
# picked back into its path from the repo root, which Neovim's own gl
# starts on, on its commit (GL_OPEN=log, GL_COMMIT, GL_PATH), with no
# file for Neovim to open. fzf is the real one, filtering for zebra
# among the commits and for f8 among the files.
mkdir -p "$HOME/gl" && (
  cd "$HOME/gl" || exit 1
  # shellcheck disable=SC2030,SC2031 # each repo's identity, for its own subshell
  export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@x
  git() { @git@/bin/git "$@"; }
  git init -q
  for i in 1 2 3 4 5 6 7 8; do
    echo "$i" >"f$i" && git add "f$i"
    GIT_AUTHOR_DATE=@$((1700000000 + i)) GIT_COMMITTER_DATE=@$((1700000000 + i)) git commit -qm "Add f$i"
  done
  GIT_AUTHOR_DATE=@1700000009 GIT_COMMITTER_DATE=@1700000009 git commit -q --allow-empty -m Empty
  git rm -q f7 f8
  t=@$(($(date +%s) - 120))
  GIT_AUTHOR_DATE=$t GIT_COMMITTER_DATE=$t git commit -qm "Delete zebra"
)
gl='. @zsh@/.config/shell/functions/git.bash
  fzf() { case "$*" in *"--accept-nth={n}"*) f=tree q=f8 ;; *) f=log q=zebra ;; esac; tee "$HOME/gl-$f" | @fzf@/bin/fzf --filter=$q "$@"; }
  COLUMNS=60 EDITOR=ed __git_log'
gl_head=$(cd "$HOME/gl" && @git@/bin/git rev-parse --short HEAD)
if [ "$(cd "$HOME/gl" && PATH=@hunkPick@/bin:@git@/bin:$PATH TZ=UTC @zsh@/bin/zsh -f -c "$gl")" = "GL_OPEN=log GL_COMMIT=$gl_head GL_PATH='f8' ed" ] &&
  [ "$(sed 's/\x1b\[[0-9;]*m//g' "$HOME/gl-log" | awk -F '\037' '{ print length($1 " " $6 $3 $4 $2) }' | sort -u)" = 57 ] &&
  awk -F '\037' -v red="$(printf '\33[1;38;2;168;77;95m-\33[0m ')" -v green="$(printf '\33[1;38;2;47;143;83m+\33[0m ')" '
    NR == 1 && $1 == " 1" && $2 == "a, 2 minutes ago" && $4 ~ /^ zebra +$/ && $6 == red { n++ }
    NR == 2 && $1 == " 2" && $4 ~ /^ Empty +$/ && $6 == "  " { n++ }
    NR == 10 && $1 == "10" && $2 == "a, 23-11-14 22:13" && $4 ~ /^ f1 +$/ && $6 == green { n++ }
    END { exit !(n == 3 && NR == 10) }' "$HOME/gl-log"; then
  ok "gl, on a real repo through the real fzf, lists commits numbered from 1, right-aligned and unsearched, each row as wide as fzf's list, their change in its colour in place of the verb it stands for and their author and date flush right, the date how long ago a commit of the last hour was made and an older one's date and time, and starts Neovim's own gl on the file picked in its commit's tree, on that commit, without opening the file"
else
  fail "gl, on a real repo through the real fzf, lists commits without their right-aligned number from 1, searches it, makes a row other than as wide as fzf's list, shows a change other than in its colour in place of its verb, dates a commit other than by how long ago (last hour) or its date and time, or does not start Neovim's own gl on the file picked in its commit's tree, on that commit, without opening the file"
fi

# Given a commit, as Neovim's gl (gl.nvim) runs it on the one picked
# here, gl lists that commit's files alone: the stand-in fzf picks two
# rows of them only, and another commit from a list of commits.
# Neovim's gl starts on the first, by its path from the repo root
# (tree-quote has no ../ to put before it, wherever gl runs).
glc='. @zsh@/.config/shell/functions/git.bash
  git() { case $1 in log) echo commit ;; rev-parse) case $2 in --show-cdup) echo ../ ;; --verify) [ "$*" != "rev-parse --verify --quiet --short abc^{commit}" ] || echo abc ;; esac ;; esac; }
  git-hunk-pick() { case $1 in tree) printf "%s\0" "$*" ;; paths) printf "x\0" ;; tree-quote) printf "%s<%s" "$*" "$(tr "\0" ,)" ;; esac; }
  fzf() { case "$*" in *"--accept-nth={n}"*) [ "$(tr "\0" "\n")" = "tree commit abc" ] && printf "4\n6\n" ;; *) echo def ;; esac; }
  EDITOR=ed __git_log abc'
if [ "$(@zsh@/bin/zsh -f -c "$glc")" = "GL_OPEN=log GL_COMMIT=abc GL_PATH=tree-quote commit abc<4, ed" ]; then
  ok "gl given a commit (Neovim's gl, on the one picked) lists that commit's files alone, and starts Neovim's gl on the first file picked, by its path from the repo root"
else
  fail "gl given a commit lists the commits first, or the files of another, or starts Neovim's gl on a file other than the first picked, or by a path other than from the repo root"
fi

# Commits marked with Tab (--multi): their files in one list, each
# commit's tree under a row of its own that no search matches (!^●),
# and tree-quote gets the first pick of the first commit with one,
# numbered from that commit's own first row, past the rows before it
# (the stand-in picks the second and the fourth): Neovim's own gl
# starts on all of the commits (GL_COMMITS), on that file (GL_PATH) in
# its commit (GL_COMMIT).
glm='. @zsh@/.config/shell/functions/git.bash
  git() { case $1 in log) [ "$2" != --no-walk ] || printf "abc\37A\ndef\37D\n" ;; rev-parse) echo ../ ;; esac; }
  git-hunk-pick() { case $1 in tree) printf "t\37%s\0" "$3" ;; paths) printf "x\0" ;; tree-quote) printf "%s<%s" "$3" "$(tr "\0" ,)" ;; esac; }
  fzf() { case "$*" in *"search(!/\$ !^●)"*) cat >/dev/null; printf "1\n3\n" ;; *--multi*) printf "abc\ndef\n" ;; esac; }
  EDITOR=ed __git_log'
if [ "$(@zsh@/bin/zsh -f -c "$glm")" = "GL_OPEN=log GL_COMMIT=abc GL_COMMITS='abc def' GL_PATH=abc<0, ed" ]; then
  ok "gl lists the files of the commits marked with Tab in one list, a row over each commit's, and starts Neovim's own gl on all of the commits, on the first file picked"
else
  fail "gl takes one commit only, or lists the files of several without a row over each that no search matches, or starts Neovim's own gl other than on all of the commits, on the first file picked"
fi

# gda, gdc and gdd (__git_diff), on a real repo through the real
# git-hunk-pick and fzf, lay out a path's row as gl lays out a
# commit's (path-rows; its own tests cover how): numbered from 1,
# right-aligned, then the path's change, in its colour (gdc's is the
# staged one: - in bold red for a deleted file, ~ in bold blue for a
# changed one, + in bold green for a new one), and its author and date
# flush right, at column COLUMNS - 3: how long ago a file saved in the
# last hour was saved, in git's words (100 seconds: 2 minutes ago), an
# older one's date and time, and nothing for a file that is gone. fzf
# searches the path only and hands it on as is: the real fzf,
# filtering for a 1, picks the one path with a 1 in it, not the paths
# numbered 1 and 10, nor those dated 1970, and quote makes it one word.
mkdir -p "$HOME/gd" && (
  cd "$HOME/gd" || exit 1
  # shellcheck disable=SC2030,SC2031 # each repo's identity, for its own subshell
  export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=u GIT_AUTHOR_EMAIL=u@x GIT_COMMITTER_NAME=u GIT_COMMITTER_EMAIL=u@x
  git() { @git@/bin/git "$@"; }
  git init -q && git config user.name u
  echo 1 >" a" && echo 1 >b && git add " a" b && git commit -qm base
  git rm -q " a" && echo 2 >b && git add b
  for f in c d e f g h "i 1" j; do echo 1 >"$f" && git add "$f"; done
  echo 2 >"i 1"
  touch -d @0 b c d e f g h j && touch -d "@$(($(date +%s) - 100))" "i 1"
)
gd() { (cd "$HOME/gd" && PATH=@hunkPick@/bin:@git@/bin:$PATH TZ=UTC @zsh@/bin/zsh -f -c "$1"); }
gdc='. @zsh@/.config/shell/functions/git.bash
  fzf() { tee "$HOME/gdc" | @fzf@/bin/fzf --filter=1 "$@"; }
  COLUMNS=40 EDITOR=ed __git_diff staged'
if [ "$(gd "$gdc")" = "GL_OPEN=staged ed -- 'i 1'" ] &&
  [ "$(tr '\0\37' '\n:' <"$HOME/gdc" | sed -n '1p;2p;9p')" = "$(printf ' a:\33[1;38;2;168;77;95m-\33[0m :%29su: 1\nb:\33[1;38;2;58;93;153m~\33[0m :%14su, 70-01-01 00:00: 2\ni 1:\33[1;38;2;47;143;83m+\33[0m :%13su, 2 minutes ago: 9' "" "" "")" ]; then
  ok "gda, gdc and gdd number their paths from 1, right-aligned, show each one's change in its colour and its author and date flush right, the date how long ago a file saved in the last hour was saved and an older one's date and time, search the paths only and hand on the path picked as is"
else
  fail "gda, gdc or gdd lists its paths without a right-aligned number, its change in its colour or its author and date flush right, dates a file saved in the last hour other than by how long ago it was saved or an older one other than by its date and time, searches more than the path or hands on more than the path picked"
fi

# gdd and gda open the paths picked in Neovim as gdc does, each in its
# own picker there (gl.nvim): GL_OPEN names it by the kind of path.
# "i 1", new and staged, has unstaged changes too: all three list it.
if [ "$(gd "${gdc% staged} unstaged")" = "GL_OPEN=unstaged ed -- 'i 1'" ] &&
  [ "$(gd "${gdc% staged}")" = "GL_OPEN=changed ed -- 'i 1'" ]; then
  ok "gdd and gda open the paths picked in Neovim's own gdd and gda (GL_OPEN=unstaged, changed)"
else
  fail "gdd or gda opens the paths picked in Neovim without naming its own picker there (GL_OPEN=unstaged, changed)"
fi

# grs (__git_reset_soft) numbers its commits from 1, for HEAD,
# right-aligned, and fzf searches past the number: the real fzf,
# filtering for a 1, picks the one commit with a 1 in it, the 10th,
# and grs resets 10 commits.
grs='. @zsh@/.config/shell/functions/git.bash
  git() { case $1 in log) printf "%s x\n" a b c d e f g h i && echo "j 1" ;; rev-list) [ "$4" != j..HEAD ] || echo 9 ;; esac; }
  fzf() { tee "$HOME/grs" | @fzf@/bin/fzf --filter=1 "$@"; }
  __git_reset_soft'
if [ "$(@zsh@/bin/zsh -f -c "$grs")" = "git reset --soft HEAD~10 " ] && [ "$(sed -n '1p;10p' "$HOME/grs")" = "$(printf ' 1 a x\n10 j 1')" ]; then
  ok "grs numbers its commits from 1, for HEAD, right-aligned and unsearched, and row n resets n commits"
else
  fail "grs lists its commits without a right-aligned number from 1, searches it, or resets other than the commits up to the row picked"
fi

# The other git pickers open as gl does, with the options they share
# (_GIT_FZF_BASE, which git-branches' pickers get too, and
# _GIT_FZF_PREVIEW_WINDOW): the search off, alt-i triggered once, the
# cursor stopping at either end of the list, and the preview below
# it, in three quarters of fzf's height. grs stands for them: its
# stand-in fzf picks the commit only when asked for all of that.
like_gl='. @zsh@/.config/shell/functions/git.bash
  git() { case $1 in log) echo "abc x" ;; rev-list) echo 0 ;; esac; }
  fzf() { case "$*" in *" --cycle"* | *"trigger(alt-i)"*"trigger(alt-i)"*) ;; *"--no-cycle "*"--bind=start:+trigger(alt-i) "*"--preview-window=down,75%,border-top,"*) head -n 1 ;; esac; }
  __git_reset_soft'
if [ "$(@zsh@/bin/zsh -f -c "$like_gl")" = "git reset --soft HEAD~1 " ]; then
  ok "the git pickers start with the search off, stop at either end of their list and preview below it, as gl does"
else
  fail "a git picker starts with the search on, cycles, or previews beside its list"
fi

# gpn (__git_create_github_repo), on real repos: gh, handed the token
# in pass, creates a private repo named after the repo's root, which
# becomes origin over SSH and gets the branch, its upstream set (a
# pushInsteadOf sends the push to a bare repo). The stand-in gh logs
# each call and prints the URL as gh does when its output is captured.
mkdir -p "$HOME/gpn" && (
  cd "$HOME/gpn" || exit 1
  # shellcheck disable=SC2030,SC2031 # each repo's identity, for its own subshell
  export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@x
  git() { @git@/bin/git "$@"; }
  git init -q --bare remote.git
  git init -q -b main proj && git -C proj commit -q --allow-empty -m first
  git -C proj config url."$HOME/gpn/remote.git".pushInsteadOf git@github.com:a/proj.git
  git init -q empty
  git init -q detached && git -C detached commit -q --allow-empty -m first && git -C detached checkout -q --detach
)
gpn='. @zsh@/.config/shell/functions/git.bash
  pass() { [ "$*" = "show GH_TOKEN" ] && echo gh-test; }
  gh() { echo "$GH_TOKEN $*" >> "$HOME/gpn/gh"; echo https://github.com/a/proj; }
  __git_create_github_repo'
gpn_in() { (cd "$HOME/gpn/$1" && PATH=@git@/bin:$PATH @zsh@/bin/zsh -f -c "$gpn" >/dev/null 2>&1); }
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^gpn +$/ && $5 == "__git_create_github_repo" && $6 == "insert" { found = 1 } END { exit !found }' &&
  gpn_in proj &&
  [ "$(cat "$HOME/gpn/gh")" = "gh-test repo create proj --private" ] &&
  [ "$(@git@/bin/git -C "$HOME/gpn/proj" config remote.origin.url)" = git@github.com:a/proj.git ] &&
  [ "$(@git@/bin/git -C "$HOME/gpn/proj" rev-parse --abbrev-ref '@{upstream}')" = origin/main ] &&
  [ "$(@git@/bin/git -C "$HOME/gpn/remote.git" rev-parse main)" = "$(@git@/bin/git -C "$HOME/gpn/proj" rev-parse HEAD)" ]; then
  ok "gpn has gh create a private repo named after the repo's root with the token in pass, makes it origin over SSH and pushes the branch to it, its upstream set"
else
  fail "gpn creates its repo under another name, public or without the token in pass, makes no SSH origin, or does not push the branch to it with its upstream set"
fi

# Run again, now that origin is set, then on a repo with no commit and
# on a detached HEAD, gpn says why and fails before calling gh, which
# would leave an empty repo on GitHub: the log still holds the one call.
# shellcheck disable=SC2069 # only gpn's stderr is captured; its stdout goes nowhere
gpn_err() { (cd "$HOME/gpn/$1" && PATH=@git@/bin:$PATH @zsh@/bin/zsh -f -c "$gpn" 2>&1 >/dev/null) && echo created; }
if [ "$(gpn_err proj)" = "Remote origin already exists: git@github.com:a/proj.git" ] &&
  [ "$(gpn_err empty)" = "No branch with a commit to push" ] &&
  [ "$(gpn_err detached)" = "No branch with a commit to push" ] &&
  [ "$(cat "$HOME/gpn/gh")" = "gh-test repo create proj --private" ]; then
  ok "gpn creates no repo with an origin already, no commit or a detached HEAD"
else
  fail "gpn creates a repo it cannot push to: with an origin already, no commit or a detached HEAD"
fi

# gg (__git_open_github), on real repos: it opens origin's page on GitHub
# once git ls-remote finds the repo there, empty as it is here, and opens
# nothing, saying why, for a repo GitHub doesn't have, an origin
# elsewhere or none; gu and guc (__git_open_url) open the branch's tree
# and commits on that page. A stand-in ssh serves GitHub's repos from a
# directory, so ls-remote talks to the real git-upload-pack, and a
# stand-in xdg-open records what it is handed. It runs in the background,
# so the refusals go first, then the openers' records are waited for and
# sorted.
mkdir -p "$HOME/gg/github/a" "$HOME/gg/bin" && (
  cd "$HOME/gg" || exit 1
  git() { @git@/bin/git "$@"; }
  git init -q --bare github/a/proj.git
  git init -q -b main proj && git -C proj remote add origin git@github.com:a/proj.git
  git init -q gone && git -C gone remote add origin git@github.com:a/gone.git
  git init -q elsewhere && git -C elsewhere remote add origin git@gitlab.com:a/proj.git
  git init -q none
)
printf '%s\n' '#!/bin/sh' 'cd "$HOME/gg/github" && exec sh -c "$2"' >"$HOME/gg/bin/ssh"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1" >>"$HOME/gg/opened"' >"$HOME/gg/bin/xdg-open"
chmod +x "$HOME/gg/bin/ssh" "$HOME/gg/bin/xdg-open"
gg_in() {
  (cd "$HOME/gg/$1" && PATH=$HOME/gg/bin:@git@/bin:$PATH GIT_SSH_COMMAND=ssh GIT_SSH_VARIANT=simple \
    @zsh@/bin/zsh -f -c ". @zsh@/.config/shell/functions/git.bash; $2")
}
gg_refused=yes
for repo in gone elsewhere none; do
  gg_in "$repo" __git_open_github 2>"$HOME/gg/$repo.err" && gg_refused=no
done
gg_in proj __git_open_github && gg_in proj __git_open_url && gg_in proj '__git_open_url commits'
for _ in $(seq 50); do
  [ "$(wc -l <"$HOME/gg/opened")" -ge 3 ] && break
  sleep 0.1
done 2>/dev/null
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^gg +$/ && $5 == "__git_open_github" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(sort "$HOME/gg/opened" 2>/dev/null)" = "https://github.com/a/proj
https://github.com/a/proj/commits/main
https://github.com/a/proj/tree/main" ]; then
  ok "gg opens origin's page on GitHub once git ls-remote finds the repo there, and gu and guc the branch's tree and commits on it"
else
  fail "gg does not open origin's page on GitHub where git ls-remote finds the repo, or gu or guc not the branch's tree or commits on it"
fi
if [ "$gg_refused" = yes ] &&
  grep -q 'Could not read from remote repository' "$HOME/gg/gone.err" &&
  [ "$(cat "$HOME/gg/elsewhere.err")" = "origin is not on GitHub: git@gitlab.com:a/proj.git" ] &&
  grep -q "No such remote 'origin'" "$HOME/gg/none.err" &&
  ! grep -q -v '^https://github.com/a/proj' "$HOME/gg/opened"; then
  ok "gg opens nothing, and says why, for a repo GitHub doesn't have, an origin elsewhere or none"
else
  fail "gg opens a page, or says nothing, for a repo GitHub doesn't have, an origin elsewhere or none"
fi

# Run from the leader (a zle widget), both of gl's steps are typed on
# the prompt's line: fzf's prompt is the last line of the shell's, as
# the shell drew it. Each step leaves its last frame up (--no-clear)
# and reads its whole list before it starts (--sync), so that the line
# doesn't go blank between frames. (The stand-ins hand on whole rows:
# the commit the line names is one.)
glw='. @zsh@/.config/shell/functions/git.bash
  git() { [ "$1" != log ] || printf "\36abc subject\n"; }
  git-hunk-pick() { case $1 in log-rows) echo abc ;; tree) echo row ;; tree-quote) tr -d "\0" ;; esac; }
  fzf() { case "$*" in *"--prompt=two% --no-bold --color=query:bold --no-clear --sync"*) head -n 1 ;; esac; }
  WIDGET=leader PS1=$(print "one\ntwo%%") EDITOR=ed __git_log'
case "$(@zsh@/bin/zsh -f -c "$glw")" in
  "GL_OPEN=log GL_COMMIT="*" GL_PATH=row ed")
    ok "gl run from the leader takes the prompt's line for its input, without blanking it as its steps start"
    ;;
  *) fail "gl run from the leader opens its input under the prompt's line, or blanks that line as its steps start" ;;
esac

# With the search off, J/K scroll the preview of each of gl's steps
# down and up 2 lines: the commits', then that of the files of the one
# picked, or of the several marked with Tab (FZF_DEFAULT_OPTS switches
# J/K with the search, as it does j/k). The stand-ins are glw's and
# glm's, with an fzf that picks only when handed that binding.
gljk='. @zsh@/.config/shell/functions/git.bash
  git() { :; }
  git-hunk-pick() { case $1 in log-rows) echo abc ;; tree) echo row ;; tree-quote) tr -d "\0" ;; esac; }
  fzf() { case "$*" in *"--bind J:preview-down+preview-down,K:preview-up+preview-up"*) head -n 1 ;; esac; }
  EDITOR=ed __git_log'
gljkm='. @zsh@/.config/shell/functions/git.bash
  git() { case $1 in log) [ "$2" != --no-walk ] || printf "abc\37A\ndef\37D\n" ;; rev-parse) echo ../ ;; esac; }
  git-hunk-pick() { case $1 in tree) printf "t\37%s\0" "$3" ;; paths) printf "x\0" ;; tree-quote) printf "%s<%s" "$3" "$(tr "\0" ,)" ;; esac; }
  fzf() { case "$*" in *"--bind J:preview-down+preview-down,K:preview-up+preview-up"*) ;; *) return ;; esac; case "$*" in *"search(!/\$ !^●)"*) cat >/dev/null; printf "1\n3\n" ;; *--multi*) printf "abc\ndef\n" ;; esac; }
  EDITOR=ed __git_log'
if [ "$(@zsh@/bin/zsh -f -c "$gljk")" = "GL_OPEN=log GL_COMMIT=abc GL_PATH=row ed" ] &&
  [ "$(@zsh@/bin/zsh -f -c "$gljkm")" = "GL_OPEN=log GL_COMMIT=abc GL_COMMITS='abc def' GL_PATH=abc<0, ed" ]; then
  ok "with the search off, J/K scroll the preview of each of gl's steps down and up 2 lines: its commits', then their files', of one commit or of several"
else
  fail "J/K do not scroll the preview of one of gl's steps: its commits', or their files', of one commit or of several"
fi
