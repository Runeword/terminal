#!/usr/bin/env bash

# shellcheck disable=SC2016
# Sourced by both bash and zsh (see config/{bash,zsh}/.{bashrc,zshrc}). The
# array syntax used here works in bash 3.2+ and zsh; the shebang documents
# intent — the file isn't executed, only sourced.
_GIT_PAGER='$(git config core.pager || echo cat)'

# POSIX-safe single-quote escape: wraps $1 in single quotes and replaces any
# embedded ' with '\''. Use when interpolating a value into a string that will
# later be evaluated by another shell (e.g. fzf --preview).
__shell_quote() {
  printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"
}

# Return non-zero (with git's own "fatal: not a git repository" message on
# stderr) when not inside a work tree. Used at the top of every function that
# reads repo state via `git rev-parse` or emits commands assuming repo context.
__git_require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1
}

# The git of every command the pickers print. --literal-pathspecs: git reads a
# path after -- as a glob, so a picked foo[1].txt would also match foo1.txt (and
# `git clean -fd` would remove both).
__git_cmd_prefix() {
  local toplevel git_dir cdup
  toplevel="$(git rev-parse --show-toplevel)" || return 1
  git_dir="$(git rev-parse --absolute-git-dir)"
  cdup="$(git rev-parse --show-cdup)"
  if [ "$git_dir" = "$toplevel/.git" ]; then
    printf 'git --literal-pathspecs -C %s' "${cdup:-.}"
  else
    printf 'git --literal-pathspecs --git-dir=%s --work-tree=%s -C %s' \
      "$(__shell_quote "$git_dir")" "$(__shell_quote "$toplevel")" "$(__shell_quote "$toplevel")"
  fi
}

# cd to the repo root and export GIT_DIR/GIT_WORK_TREE, in the subshell a picker
# runs git-hunk-pick and fzf in (it changes the calling shell): the lists are
# relative to the root, and git there, including fzf's preview and bind commands,
# must still find a git dir that isn't discoverable from the toplevel (e.g.
# ~/.dotfiles with core.worktree=$HOME).
__git_cd_root() {
  local root git_dir
  root="$(git rev-parse --show-toplevel)" || return 1
  git_dir="$(git rev-parse --absolute-git-dir)" || return 1
  builtin cd "$root" || return 1
  export GIT_DIR="$git_dir" GIT_WORK_TREE="$root"
}

__git_clone() {
  local repo_url="${2:-$(wl-paste)}" # Use clipboard content if no URL is provided
  local base_dir="${HOME}/${1}"
  mkdir -p "$base_dir" # Create the base directory if it doesn't exist
  git clone "$repo_url" "$base_dir/$(basename "$repo_url" .git)"
  builtin cd "$base_dir/$(basename "$repo_url" .git)" || return # Change into the cloned directory
}

__git_open_url() {
  __git_require_repo || return 1

  local REMOTE_URL
  REMOTE_URL=$(git remote get-url origin) || return 1

  # Normalize any git remote URL form to https://host/owner/repo. Covers:
  #   git@host:owner/repo[.git]                  (scp-like SSH)
  #   ssh://[git@]host[:port]/owner/repo[.git]   (SSH protocol, with optional port)
  #   git://host/owner/repo[.git]                (git protocol)
  #   http(s)://host/owner/repo[.git]            (HTTPS/HTTP)
  # The previous single regex hardcoded `github.com` in the output and only
  # matched the scp-like SSH form, so HTTPS clones or any non-GitHub remote
  # produced a wrong URL. A user[:token]@ before the host is dropped: the URL
  # goes to the browser, and into its history.
  local REPO_URL
  REPO_URL=$(printf '%s\n' "$REMOTE_URL" | sed -E \
    -e 's#^git@([^:]+):#https://\1/#' \
    -e 's#^ssh://(git@)?([^/:]+)(:[0-9]+)?/#https://\2/#' \
    -e 's#^git://([^/]+)/#https://\1/#' \
    -e 's#^http://#https://#' \
    -e 's#^https://[^/]*@#https://#' \
    -e 's#\.git$##')

  # Branch name when attached, or full sha when detached (GitHub treats the
  # literal string "HEAD" in URLs as a branch name and 404s).
  local BRANCH
  BRANCH=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)

  local FINAL_URL="${REPO_URL}/${1:-tree}/${BRANCH}"

  if command -v xdg-open >/dev/null 2>&1; then
    (nohup xdg-open "$FINAL_URL" >/dev/null 2>&1 &)
  elif command -v open >/dev/null 2>&1; then
    open -a "$BROWSER" "$FINAL_URL"
  else
    return 1
  fi
}

# fzf args used by every picker. Arrays (not strings) so values containing
# spaces or quotes round-trip through `"${arr[@]}"` without re-parsing — the
# previous string form required `eval` or `sh -c` everywhere it was consumed.
_GIT_FZF_BASE=(
  --reverse --no-separator --keep-right
  --border none
  --cycle
  --height 70%
  --info=inline:
  --header-first
  '--prompt=  '
  --wrap-sign=
  --scheme=path
)
_GIT_FZF_MULTI=(--multi --bind=ctrl-a:select-all)
_GIT_FZF_DEFAULT=("${_GIT_FZF_BASE[@]}" "${_GIT_FZF_MULTI[@]}")
# Used as the leading clause of every --preview value; keeps the focused
# line visible above the preview body.
_GIT_FZF_PREVIEW_CMD="echo {};"
# Used as the value of --preview-window=...
_GIT_FZF_PREVIEW_WINDOW="right,75%,border-none,wrap,~1"

__git_diff_tracked() {
  local ph="$1" root quoted
  [ -n "$ph" ] || ph='{}'
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local check="git --literal-pathspecs -C $quoted ls-files --error-unmatch -- $ph > /dev/null 2>&1"
  local diff="git --literal-pathspecs -C $quoted diff --ignore-space-change --color=always -- $ph | $_GIT_PAGER"
  printf '{ %s && %s; }' "$check" "$diff"
}

# The path goes after -- here as everywhere: git diff obeys an option even after
# its paths, so an untracked file named --output=flake.nix, merely previewed,
# would truncate flake.nix.
__git_diff_untracked() {
  local ph="$1" root quoted
  [ -n "$ph" ] || ph='{}'
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local link="cd $quoted && test -L $ph && readlink -- $ph"
  local dir="cd $quoted && test -d $ph && ls -la -- $ph"
  local diff="cd $quoted && ! test -L $ph && git diff --ignore-space-change --no-index --color=always -- /dev/null $ph | $_GIT_PAGER"
  printf '{ %s || %s || %s; }' "$link" "$dir" "$diff"
}

__git_diff_staged() {
  local ph="$1" root quoted
  [ -n "$ph" ] || ph='{}'
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local check="git --literal-pathspecs -C $quoted diff --cached --name-only -- $ph | grep -q ."
  local diff="git --literal-pathspecs -C $quoted diff --ignore-space-change --cached --color=always -- $ph | $_GIT_PAGER"
  printf '{ %s && %s; }' "$check" "$diff"
}

# Pick paths of kind $1 with fzf (the default args plus any extras after $2)
# and print them as the words of a command: shell-quoted, space-joined, each
# prefixed with $2. `git-hunk-pick paths` lists the kind (staged, unstaged,
# changed, untracked, ignored: packages/git/hunk-pick/paths.go) from the repo
# root, so the paths are relative to it: pass "" for a `git -C <root>` command,
# or the cd-up path (git rev-parse --show-cdup) for one that runs from the
# invocation cwd, like $EDITOR. NUL-separated end to end (--read0/--print0,
# then `git-hunk-pick quote`), so a path git would quote (café.txt, a tab or
# newline in it, a space in a status line) reaches the command as is.
__git_fzf_select() {
  local kind="$1" prefix="$2"
  shift 2

  (
    __git_cd_root || exit 1
    git-hunk-pick paths "$kind" </dev/null |
      fzf --read0 --print0 "${_GIT_FZF_DEFAULT[@]}" "$@"
  ) | git-hunk-pick quote "$prefix"
}

# Two-level stage / unstage / discard / stash picker (ga/gru/grd/gsp). $1 is the
# op. git-hunk-pick decides what each op lists, drills and prints (pickOps in
# packages/git/hunk-pick); only the preview differs here:
#
#   op       files listed          preview diff
#   stage    unstaged + untracked  tracked/untracked
#   unstage  staged                staged
#   discard  unstaged (tracked)    tracked
#   stash    unstaged + untracked  tracked/untracked
#
# ONE fzf shows either the files list or, drilled into a file, that file's hunks: a
# drill (Enter / Right) and a return (Left / Esc) reload-sync the other list in place,
# so the picker keeps its rows and never blanks the screen (a nested hunks fzf run by
# `execute` could do neither: fzf pauses onto the alternate screen to run it).
# Whole-file selection is fzf's NATIVE multi-select: Tab selects, Shift-Tab deselects,
# Ctrl-A selects all (or clears), all in-process. `git-hunk-pick key` handles the
# four keys whose meaning depends on the list shown; a reload wipes native marks, so a
# drill saves the files list's marks and query, and each switch queues what must land
# with the new list (header, marks, cursor, query, the hunk preselection) for `load`,
# which fzf runs before it paints the reloaded list. git-hunk-pick keeps each drilled
# file's hunk spec (ALL or its hunk indices): a drill opens with the spec marked (a
# Tab-marked file: every hunk), leaving records the marks WYSIWYG and selects or
# deselects the file to match. Enter in the hunks list, or on a file without hunks,
# accepts, and `git-hunk-pick finalize` prints the command (leader flag `e`): whole
# files (ALL) batched into one whole-file command, each hunk subset its own clause,
# which applies nothing if the file's picked hunks changed since. Esc in the files list
# cancels. The lists are NUL-separated (--read0, and --print0 for {+f}), so a path git
# would quote (café.txt, a tab or newline in the name) reaches every command as is.
__git_pick_files() {
  __git_require_repo || return 1

  local diff_preview
  case "$1" in
    stage | stash) diff_preview="$(__git_diff_tracked '{}') || $(__git_diff_untracked '{}')" ;;
    unstage) diff_preview="$(__git_diff_staged '{}')" ;;
    discard) diff_preview="$(__git_diff_tracked '{}')" ;;
    *) return 1 ;;
  esac

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"

  # The state the picker turns into fzf actions and the printed command lives in
  # the per-user runtime dir: the claude sandbox shares /tmp, while it has a
  # private $XDG_RUNTIME_DIR.
  local sd sdq
  sd="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/git-pick.XXXXXX")" || return 1
  sdq="$(__shell_quote "$sd")"

  # One preview for both lists: a hunk ($sd/.drill exists while drilled) shows that
  # hunk alone; a file shows its path, a partial hint (git-hunk-pick hint prints a
  # line only for a drilled hunk SUBSET), then its diff. {n} is the focused row's
  # 0-based index, and git-hunk-pick numbers hunks from 1.
  local -a preview=(
    --preview "if [ -e $sdq/.drill ]; then echo {}; git-hunk-pick assemble \$(({n} + 1)) <$sdq/.diff | $_GIT_PAGER; else echo {}; git-hunk-pick hint $sdq {}; $diff_preview; fi"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )

  # `git-hunk-pick files` also saves the list to $sd/.files, which a return reloads;
  # its stdin is /dev/null so it can't wait on the terminal fzf reads. key's args end
  # with {+n} because it expands to one word per selected index.
  # Left-anchored (--no-keep-right overrides the shared/global keep-right) so a long
  # path is not scrolled off screen behind a leading ellipsis. The ctrl-a bind keeps
  # $FZF_SELECT_COUNT/$FZF_MATCH_COUNT single-quoted so fzf (not the shell) expands
  # them; scope SC2016 to the subshell instead of fighting the formatter.
  local key_cmd="git-hunk-pick key $sdq $1"
  # shellcheck disable=SC2016
  (
    __git_cd_root || exit 1
    git-hunk-pick files "$sd" "$1" </dev/null |
      fzf "${_GIT_FZF_DEFAULT[@]}" \
        --read0 --print0 \
        --no-keep-right \
        --bind "enter:transform($key_cmd enter {+f} {} {+n})" \
        --bind "right:transform($key_cmd right {+f} {} {+n})" \
        --bind "left:transform($key_cmd left {+f} {} {+n})" \
        --bind "esc:transform($key_cmd esc {+f} {} {+n})" \
        --bind "load:transform(git-hunk-pick load $sdq)" \
        --bind "tab:select+down" \
        --bind "btab:deselect+up" \
        --bind 'ctrl-a:transform([ "${FZF_SELECT_COUNT:-0}" -eq "${FZF_MATCH_COUNT:-0}" ] && echo deselect-all || echo select-all)' \
        "${preview[@]}"
  ) >/dev/null

  git-hunk-pick finalize "$sd" "$1" "$git_cmd"
  rm -rf "$sd"
}

__git_add() {
  __git_pick_files stage
}

__git_commit() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select changed '' "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd add -- $args && $git_cmd commit "
}

__git_unstage() {
  __git_pick_files unstage
}

__git_discard() {
  __git_pick_files discard
}

__git_untrack() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select staged '' "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd rm --cached -- $args"
}

__git_rm_untracked() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_untracked)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select untracked '' "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd clean -fd -- $args"
}

__git_ignore() {
  __git_require_repo || return 1

  local action="${1:-open}"
  local cmd
  # Every $EDITOR command gets its paths after --: nvim runs a +cmd argument
  # as an Ex command, so a file named "+so x.vim" would source x.vim.
  case "$action" in
    open) cmd="$EDITOR --" ;;
    remove | rm) cmd="rm --" ;;
    *)
      echo "Usage: __git_ignore [open|remove]"
      return 1
      ;;
  esac

  local repo_root quoted_repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  quoted_repo_root="$(__shell_quote "$repo_root")"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD cd $quoted_repo_root && ls -la -- {}"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  # $cmd runs from the invocation cwd: prefix the root-relative paths.
  local args
  args=$(__git_fzf_select ignored "$(git rev-parse --show-cdup)" "${preview[@]}")
  [ "$args" != "" ] && echo "$cmd $args"
}

__git_diff() {
  __git_require_repo || return 1

  local repo_cdup kind
  repo_cdup="$(git rev-parse --show-cdup)"
  local -a preview

  case "${1:-all}" in
    staged)
      kind=staged
      preview=(
        --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)"
        --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
      )
      ;;
    unstaged)
      kind=unstaged
      preview=(
        --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)"
        --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
      )
      ;;
    *)
      kind=changed
      preview=(
        --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)"
        --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
      )
      ;;
  esac

  local args
  args=$(__git_fzf_select "$kind" "$repo_cdup" "${preview[@]}")
  [ "$args" != "" ] && echo "$EDITOR -- $args"
}

__git_diff_branches() {
  git-branches diff-branches "${_GIT_FZF_BASE[@]}"
}

__git_diff_revs() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"

  local -a rev_preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always --stat {1} | $_GIT_PAGER"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )

  local rev_a rev_b file_a file_b
  rev_a=$(git log --oneline --all | fzf "${_GIT_FZF_BASE[@]}" "${rev_preview[@]}" \
    --header='side A: pick rev' | awk '{print $1}')
  [ "$rev_a" = "" ] && return

  # `paths tree` lists the rev's whole tree from any directory, relative to the
  # root as REV:path reads it, NUL-separated so any name comes back as is.
  file_a=$(git-hunk-pick paths tree "$rev_a" </dev/null | fzf --read0 "${_GIT_FZF_BASE[@]}" \
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always $rev_a:{} | $_GIT_PAGER" \
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW" \
    --header="side A: pick file in $rev_a")
  [ "$file_a" = "" ] && return

  rev_b=$(git log --oneline --all | fzf "${_GIT_FZF_BASE[@]}" "${rev_preview[@]}" \
    --header='side B: pick rev' | awk '{print $1}')
  [ "$rev_b" = "" ] && return

  file_b=$(git-hunk-pick paths tree "$rev_b" </dev/null | fzf --read0 "${_GIT_FZF_BASE[@]}" \
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always $rev_b:{} | $_GIT_PAGER" \
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW" \
    --header="side B: pick file in $rev_b")
  [ "$file_b" = "" ] && return

  echo "$git_cmd diff $(__shell_quote "$rev_a:$file_a") $(__shell_quote "$rev_b:$file_b")"
}

# Write a patch for staged, unstaged, or committed changes. Echoes the command
# for review (leader flag `e`) instead of running it, so the output path and
# commit range can be tweaked before anything is written.
#   staged/unstaged -> single plain diff, apply with `git apply`
#   committed       -> format-patch: one mailbox file per commit in ./patches,
#                      apply with `git am` (preserves message + authorship)
__git_patch() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"

  case "${1:-staged}" in
    staged)
      echo "$git_cmd diff --staged > staged.patch"
      ;;
    unstaged)
      echo "$git_cmd diff > unstaged.patch"
      ;;
    committed)
      local -a preview=(
        --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always --stat --decorate {1} | $_GIT_PAGER"
        --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
      )
      local commit
      commit=$(git log --oneline --first-parent |
        fzf "${_GIT_FZF_BASE[@]}" "${preview[@]}" \
          --header='format-patch every commit from the selected one through HEAD' |
        awk '{print $1}')
      [ "$commit" = "" ] && return
      # Range start is exclusive, so <commit>~1 makes the picked commit itself
      # the first patch; -o writes the NNNN-*.patch files into ./patches.
      echo "$git_cmd format-patch $commit~1 -o patches"
      ;;
  esac
}

__git_reset_soft() {
  __git_require_repo || return 1

  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always --decorate {1} | $_GIT_PAGER"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local commit
  commit=$(git log --oneline --first-parent | fzf "${_GIT_FZF_BASE[@]}" "${preview[@]}" | awk '{print $1}')

  if [ "$commit" != "" ]; then
    local offset
    offset=$(git rev-list --count --first-parent "$commit"..HEAD)
    echo "git reset --soft HEAD~$((offset + 1)) "
  fi
}

# Makes the current branch identical to its origin counterpart, dropping its
# local commits and changes
__git_reset_to_remote() {
  git reset --hard "origin/$(git branch --show-current)"
}

# Opens the files the current branch changed since it left master. Paths go
# after --: nvim runs a +cmd argument, so a file named "+so x.vim" would
# source x.vim.
__git_open_branch_files() {
  local -a files=()
  local file
  while IFS= read -r file; do
    files+=("$file")
  done < <(git diff --name-only master...)
  nvim -- "${files[@]}"
}

# Drop one commit from history while preserving the content of every other
# commit. The descendants necessarily get new SHAs (a git commit hashes its
# parent), which is harmless while they are unpushed — so by default only
# unpushed, non-merge commits are offered and published history can't be
# rewritten by accident; pass a rev-range as $1 to widen the scope. Echoes
# `git rebase --onto <sha>~1 <sha>` for review (leader flag `e`) rather than
# running it, like __git_reset_soft.
__git_drop_commit() {
  __git_require_repo || return 1

  local range header
  if [ -n "$1" ]; then
    range="$1"
    header='drop commit — pick one to remove'
  elif git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
    range='@{upstream}..HEAD'
    header='drop an unpushed commit'
  else
    range='HEAD'
    header='drop commit (no upstream — showing all history)'
  fi

  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always --stat --decorate {1} | $_GIT_PAGER"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local commit
  commit=$(git log --oneline --no-merges "$range" |
    fzf "${_GIT_FZF_BASE[@]}" "${preview[@]}" --header="$header" | awk '{print $1}')

  [ "$commit" = "" ] && return

  # --onto <sha>~1 <sha> replays the picked commit's descendants onto its
  # parent, dropping just that commit. Conflicts only if a later commit
  # touched the same lines. Echoed for review; press enter to run.
  echo "git rebase --onto $commit~1 $commit "
}

__git_log() {
  __git_require_repo || return 1

  # The preview goes below the list, not to its right as in the other pickers:
  # the list then has the full width, where a quarter of it would cut the
  # commit subjects and the tree's deeper rows. The preview takes three
  # quarters of fzf's height, which leaves the list a few rows, enough to pick
  # from. Even then, git's header and message would fill much of the preview,
  # and a commit's row has its author and date, so its preview is the diff
  # alone ({2} is the row's hash, see below): --format= leaves out the header,
  # and sed the blank line delta puts before the diff.
  local preview_window='down,75%,border-top,wrap'
  local -a preview=(
    --preview "git show --color=always --format= {2} | $_GIT_PAGER | sed '1{/^\$/d}'"
    --preview-window="$preview_window"
  )

  # Run from the leader (a zle widget, at an empty prompt), each step's input
  # is typed on the prompt's line: fzf's prompt repeats the last line of the
  # shell's (the right prompt gives way to fzf's line), and --no-clear starts
  # fzf on the cursor's line rather than below it. It also leaves fzf's last
  # frame up, until the next step's first frame replaces it or zle clears it
  # as it redraws the prompt. fzf blanks its first line as it starts and
  # draws 20ms later, unless --sync, which has it read its whole list before
  # it starts and then draw at once: either gap showed as a flicker of the
  # prompt's line. --no-bold leaves the prompt as the shell drew it, where
  # prompt:regular would drop its italics too, and query:bold keeps the query
  # as it was. The file step's header goes under the input line, not above.
  local -a inline=()
  if [ -n "${WIDGET-}" ]; then
    local ps1
    ps1=$(print -rP -- "$PS1")
    inline=("--prompt=${ps1##*$'\n'}" --no-bold --color=query:bold --no-header-first --no-clear --sync)
  fi

  # A commit's row is its hash and subject, then its author and date flush
  # right, with no colour of their own, so that fzf shows and highlights them
  # as the rest of the row. git pads the subject, or cuts it, up to column
  # $COLUMNS - 4 and adds a space, so that a row is as wide as fzf's list,
  # $COLUMNS less its pointer, marker and scrollbar columns. git counts that
  # column from the start of the line, so it prints the author and date
  # first, and fzf shows them last (--with-nth): the subject then ends where
  # they leave it room. The fields are 0x1f-separated: author and date, hash,
  # subject and, hidden, the row as git log --oneline prints it, which y
  # copies. fzf prints the hash of the row picked. Both steps start with the
  # search off, as alt-i leaves it (FZF_DEFAULT_OPTS): j/k, g/G, f, q and y act
  # at once, and i turns the search on.
  local -a log_view=(
    --delimiter=$'\x1f' --with-nth='{2}{3}{1}' --accept-nth=2
    --bind 'start:+trigger(alt-i)'
    --bind 'y:execute-silent(wl-copy -- {4})'
  )
  local commit
  commit=$(git log --format="%an, %ar%x1f%h%x1f %<|($((COLUMNS - 4)),trunc)%s %x1f%h %s" |
    fzf "${_GIT_FZF_BASE[@]}" "${inline[@]}" "${preview[@]}" "${log_view[@]}")

  [ "$commit" = "" ] && return

  local -a file_preview=(
    --header='select files to open'
    # {2..} is the row's path, a directory's ending in /, so that its preview
    # is every change below it, under the path, which stays at the top as the
    # diff scrolls (~1). `:(top,literal)` anchors the pathspec to the repo
    # root (the listed paths are root-relative but this fzf runs from the
    # invocation cwd) and reads it as a path, not a glob. --format= leaves out
    # the header of the commit, picked in the step before, and sed the blank
    # line delta puts before the diff.
    --preview "echo {2..}; git show --color=always --format= $commit -- ':(top,literal)'{2..} | $_GIT_PAGER | sed '1{/^\$/d}'"
    --preview-window="$preview_window,~1"
  )

  # git-hunk-pick tree prints a row per directory and file of the commit: the
  # tree's row and the path, 0x1f-separated (tree.go). Raw mode keeps the whole
  # tree on screen while a query is typed and dims the rows that don't match.
  # Every search also requires !/$ (doesn't end in /), so a directory's row
  # never matches and can't be picked: the cursor goes to the best match, the
  # arrows, j/k and Tab step between matches, and Tab, Enter, f's jump and the
  # mouse's clicks act on a match only (Enter on the marks too). fzf counts
  # every row, so the info line counts the files instead: matches over
  # TREE_FILES, the commit's files. fzf prints the picked rows' indices, which
  # tree-quote turns back into paths. y copies the row's path. alt-i turns the
  # search off before search(!/$), as turning it off after cancels that search.
  local accept='[ "$FZF_RAW" = 1 ] || [ "$FZF_SELECT_COUNT" != 0 ] && echo accept'
  local -a tree_view=(
    --ansi --raw --gutter-raw=' ' --delimiter=$'\x1f' --with-nth='{1}' --accept-nth='{n}'
    --bind 'start:+trigger(alt-i)+search(!/$),change:transform-search:printf "%s !/$" "$FZF_QUERY"'
    --bind 'result:best,up:up-match,down:down-match,j:down-match,k:up-match,btab:deselect+up-match'
    --bind 'tab:transform:[ "$FZF_RAW" = 1 ] && echo select+down-match || echo down-match'
    --bind 'right-click:transform:[ "$FZF_RAW" = 1 ] && echo toggle'
    --bind "enter:transform:$accept" --bind "double-click:transform:$accept"
    --bind "f:jump,jump:transform:$accept"
    --bind 'y:execute-silent(wl-copy -- {2..})'
    --info-command='printf "%s/%s (%s)" "$FZF_MATCH_COUNT" "$TREE_FILES" "$FZF_SELECT_COUNT"'
  )

  local repo_cdup files
  repo_cdup="$(git rev-parse --show-cdup)"
  files=$(($(git-hunk-pick paths commit "$commit" </dev/null | tr -cd '\000' | wc -c)))
  local args
  args=$(git-hunk-pick tree commit "$commit" </dev/null |
    TREE_FILES=$files fzf --read0 --print0 "${_GIT_FZF_DEFAULT[@]}" "${inline[@]}" "${tree_view[@]}" "${file_preview[@]}" |
    git-hunk-pick tree-quote commit "$commit" "$repo_cdup")
  [ "$args" != "" ] && echo "$EDITOR -- $args"
}

__git_install_lefthook() {
  local repo_url="https://github.com/Runeword/lefthook"
  local api_url="https://api.github.com/repos/Runeword/lefthook/contents"

  local response
  response=$(curl -fsS "$api_url") || {
    echo "Failed to fetch repository contents from $api_url" >&2
    return 1
  }

  local available_configs
  available_configs=$(printf '%s' "$response" | jq -r '
    .[]?
    | select(.type == "file")
    | .name
    | select(endswith(".yml"))
    | select(. != "lefthook.yml")
  ') || {
    echo "Failed to parse GitHub API response as JSON" >&2
    return 1
  }

  if [ "$available_configs" = "" ]; then
    echo "No installable hook configs found in $repo_url" >&2
    return 1
  fi

  local -a preview=(
    --header='select git hooks to install'
    --preview "$_GIT_FZF_PREVIEW_CMD curl -s https://raw.githubusercontent.com/Runeword/lefthook/main/{}"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )

  local selected_configs
  selected_configs=$(echo "$available_configs" | fzf "${_GIT_FZF_DEFAULT[@]}" "${preview[@]}")

  if [ "$selected_configs" != "" ]; then
    local nl=$'\n'
    {
      echo "remotes:"
      echo "  - git_url: $repo_url"
      echo "    configs:"
      echo "      - ${selected_configs//$nl/$nl      - }"
    } >lefthook.yml
    lefthook install
  fi
}

__git_info() {
  __git_require_repo || return 1
  printf "\033[3mgit config user.name\033[23m\n"
  git config user.name
  echo
  printf "\033[3mgit config user.email\033[23m\n"
  git config user.email
  echo
  printf "\033[3mgit remote -v\033[23m\n"
  git remote -v
  echo
  printf "\033[3mgit --no-pager log --oneline --decorate -n 5\033[23m\n"
  git --no-pager log --oneline --decorate -n 5
  echo
  printf "\033[3mgit --no-pager log --oneline --decorate -n 5 @{upstream}\033[23m\n"
  printf '⟳ fetching origin…\n'
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=3' \
    git fetch --quiet >/dev/null 2>&1
  printf '\033[1A\r\033[J'
  git --no-pager log --oneline --decorate -n 5 '@{upstream}' 2>/dev/null || echo '(current branch has no upstream)'
}

__git_set_user() {
  git config user.name "Runeword"
  git config user.email "60324746+Runeword@users.noreply.github.com"
}

__git_worktree_add() {
  git-branches worktree-add "${_GIT_FZF_BASE[@]}"
}

__git_worktree_remove() {
  git-branches worktree-remove "${_GIT_FZF_BASE[@]}"
}

__git_worktree_switch() {
  git-branches worktree-switch "${_GIT_FZF_BASE[@]}"
}

__git_merge() {
  git-branches merge "${_GIT_FZF_BASE[@]}"
}

__git_branch_switch() {
  git-branches switch "${_GIT_FZF_BASE[@]}" --header='switch to branch'
}

__git_lefthook_pre_commit() {
  __git_require_repo || return 1

  # Ask lefthook to dump its own merged config (extends resolved by lefthook,
  # not us) and extract every selectable name. Commands (legacy `commands:`
  # map) take the `--command` flag; jobs (new `jobs:` syntax, possibly nested
  # under `group:`) take `--job`. Column 1 of each line is the kind so the
  # caller knows which flag to emit; fzf shows only the name (column 2).
  local listing
  # Outer parens around each comma-separated clause are load-bearing: jq's `,`
  # binds tighter than `|`, so without them the second clause leaks into the
  # first's pipeline and the whole expression silently produces nothing.
  listing=$(lefthook dump --format=json | jq -r '
    ((."pre-commit".commands // {}) | to_entries[]? | "command\t" + .key),
    ((."pre-commit".jobs     // []) | .. | objects | select(.name) | "job\t" + .name)
  ' | sort -u) || {
    echo "lefthook dump failed (not a lefthook repo, or invalid config)" >&2
    return 1
  }

  if [ "$listing" = "" ]; then
    echo "No pre-commit commands or jobs found in lefthook config"
    return 1
  fi

  local selected
  selected=$(echo "$listing" | fzf "${_GIT_FZF_DEFAULT[@]}" \
    --height 40% --header='select commands' \
    --delimiter=$'\t' --with-nth=2)

  if [ "$selected" = "" ]; then
    echo "No commands selected"
    return 0
  fi

  local -a flags=()
  local kind name
  while IFS=$'\t' read -r kind name; do
    case "$kind" in
      command) flags+=(--command "$name") ;;
      job) flags+=(--job "$name") ;;
    esac
  done <<<"$selected"

  echo "Running: lefthook run --all-files ${flags[*]} pre-commit"
  lefthook run --all-files "${flags[@]}" pre-commit
}

__git_cherry_pick() {
  git-branches cherry-pick "${_GIT_FZF_BASE[@]}"
}

__git_stash_push() {
  __git_pick_files stash
}

__git_stash_apply() {
  git-branches stash-apply "${_GIT_FZF_BASE[@]}"
}
