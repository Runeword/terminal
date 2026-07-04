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

__git_cmd_prefix() {
  local toplevel git_dir cdup
  toplevel="$(git rev-parse --show-toplevel)" || return 1
  git_dir="$(git rev-parse --absolute-git-dir)"
  cdup="$(git rev-parse --show-cdup)"
  if [ "$git_dir" = "$toplevel/.git" ]; then
    printf 'git -C %s' "${cdup:-.}"
  else
    printf 'git --git-dir=%s --work-tree=%s -C %s' \
      "$(__shell_quote "$git_dir")" "$(__shell_quote "$toplevel")" "$(__shell_quote "$toplevel")"
  fi
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
  # produced a wrong URL.
  local REPO_URL
  REPO_URL=$(printf '%s\n' "$REMOTE_URL" | sed -E \
    -e 's#^git@([^:]+):#https://\1/#' \
    -e 's#^ssh://(git@)?([^/:]+)(:[0-9]+)?/#https://\2/#' \
    -e 's#^git://([^/]+)/#https://\1/#' \
    -e 's#^http://#https://#' \
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
  local root quoted
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local check="git -C $quoted ls-files --error-unmatch -- {} > /dev/null 2>&1"
  local diff="git -C $quoted diff --ignore-space-change --color=always -- {} | $_GIT_PAGER"
  printf '{ %s && %s; }' "$check" "$diff"
}

__git_diff_untracked() {
  local root quoted
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local link="cd $quoted && test -L {} && readlink {}"
  local diff="cd $quoted && ! test -L {} && git diff --ignore-space-change --no-index --color=always /dev/null {} | $_GIT_PAGER"
  printf '{ %s || %s; }' "$link" "$diff"
}

__git_diff_staged() {
  local root quoted
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local check="git -C $quoted diff --cached --name-only -- {} | grep -q ."
  local diff="git -C $quoted diff --ignore-space-change --cached --color=always -- {} | $_GIT_PAGER"
  printf '{ %s && %s; }' "$check" "$diff"
}

# Run a list command from the repo root, pipe its output into fzf with the
# default args plus any extras passed positionally, then emit a shell-quoted,
# space-joined argv suitable for interpolating into a `git ... -- $args` line.
# fzf is invoked directly (no `sh -c`) so caller-supplied args can be quoted
# correctly via array splat.
# GIT_DIR/GIT_WORK_TREE are exported in the subshell so the list command and
# fzf preview commands still resolve the repo when its git dir isn't
# discoverable from the toplevel (e.g. ~/.dotfiles with core.worktree=$HOME).
__git_fzf_select() {
  local list_cmd="$1"
  shift
  local repo_root git_dir
  repo_root="$(git rev-parse --show-toplevel)"
  git_dir="$(git rev-parse --absolute-git-dir)"

  local result
  result=$(
    builtin cd "$repo_root" || exit 1
    export GIT_DIR="$git_dir" GIT_WORK_TREE="$repo_root"
    sh -c "$list_cmd" | fzf --print0 "${_GIT_FZF_DEFAULT[@]}" "$@"
  )
  [ "$result" = "" ] && return 1
  printf '%s' "$result" | tr '\0' '\n' | sed "s/'/'\\\\''/g; s/.*/'&'/" | tr '\n' ' '
}

__git_add() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select \
    "{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq" \
    "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd add -- $args"
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
  args=$(__git_fzf_select \
    "{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq" \
    "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd add -- $args && $git_cmd commit "
}

__git_unstage() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "${preview[@]}")
  # `restore --staged` restores from HEAD; before the first commit use `rm --cached`
  local unstage="restore --staged"
  git rev-parse --verify --quiet HEAD >/dev/null || unstage="rm --cached"
  [ "$args" != "" ] && echo "$git_cmd $unstage -- $args"
}

__git_discard() {
  __git_require_repo || return 1

  local git_cmd
  git_cmd="$(__git_cmd_prefix)"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local args
  args=$(__git_fzf_select "git diff --name-only" "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd checkout -- $args"
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
  args=$(__git_fzf_select "git diff --name-only --cached" "${preview[@]}")
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
  args=$(__git_fzf_select "git ls-files --others --exclude-standard" "${preview[@]}")
  [ "$args" != "" ] && echo "$git_cmd clean -f -- $args"
}

__git_ignore() {
  __git_require_repo || return 1

  local action="${1:-open}"
  local cmd
  case "$action" in
  open) cmd="$EDITOR" ;;
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
  local args
  args=$(__git_fzf_select "git status --ignored --porcelain | grep '^!!' | cut -c4-" "${preview[@]}")
  [ "$args" != "" ] && echo "$cmd $args"
}

__git_diff() {
  __git_require_repo || return 1

  local repo_cdup list_cmd
  repo_cdup="$(git rev-parse --show-cdup)"
  local -a preview

  case "${1:-all}" in
  staged)
    list_cmd="git diff --name-only --cached"
    preview=(
      --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)"
      --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
    )
    ;;
  unstaged)
    list_cmd="{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq"
    preview=(
      --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)"
      --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
    )
    ;;
  *)
    list_cmd="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
    preview=(
      --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)"
      --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
    )
    ;;
  esac

  local args
  args=$(__git_fzf_select "$list_cmd" "${preview[@]}")
  [ "$args" != "" ] && echo "$EDITOR ${repo_cdup:+$repo_cdup}$args"
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

  file_a=$(git ls-tree -r --name-only "$rev_a" | fzf "${_GIT_FZF_BASE[@]}" \
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always $rev_a:{} | $_GIT_PAGER" \
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW" \
    --header="side A: pick file in $rev_a")
  [ "$file_a" = "" ] && return

  rev_b=$(git log --oneline --all | fzf "${_GIT_FZF_BASE[@]}" "${rev_preview[@]}" \
    --header='side B: pick rev' | awk '{print $1}')
  [ "$rev_b" = "" ] && return

  file_b=$(git ls-tree -r --name-only "$rev_b" | fzf "${_GIT_FZF_BASE[@]}" \
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always $rev_b:{} | $_GIT_PAGER" \
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW" \
    --header="side B: pick file in $rev_b")
  [ "$file_b" = "" ] && return

  echo "$git_cmd diff $(__shell_quote "$rev_a:$file_a") $(__shell_quote "$rev_b:$file_b")"
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

__git_log() {
  __git_require_repo || return 1

  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always --decorate {1} | $_GIT_PAGER"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )
  local commit
  commit=$(git log --oneline | fzf "${_GIT_FZF_BASE[@]}" "${preview[@]}" | awk '{print $1}')

  [ "$commit" = "" ] && return

  local -a file_preview=(
    --header='select files to open'
    # `:/` anchors the pathspec to the repo root; the listed paths are
    # root-relative but this fzf runs from the invocation cwd.
    --preview "$_GIT_FZF_PREVIEW_CMD git show --color=always $commit -- :/{} | $_GIT_PAGER"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local args
  args=$(git diff-tree --root --no-commit-id --name-only -r "$commit" |
    fzf --print0 "${_GIT_FZF_DEFAULT[@]}" "${file_preview[@]}" |
    tr '\0' '\n' | sed "s/'/'\\\\''/g; s/.*/'&'/" | tr '\n' ' ')
  [ "$args" != "" ] && echo "$EDITOR ${repo_cdup:+$repo_cdup}$args"
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
    {
      echo "remotes:"
      echo "  - git_url: $repo_url"
      echo "    configs:"
      echo "$selected_configs" | sed 's/^/      - /'
    } >lefthook.yml
    lefthook install
  fi
}

__git_info() {
  printf "\033[3mgit config user.name\033[23m\n"
  git config user.name
  echo
  printf "\033[3mgit config user.email\033[23m\n"
  git config user.email
  echo
  printf "\033[3mgit remote -v\033[23m\n"
  git remote -v
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
  __git_require_repo || return 1

  local list_files="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
  local -a preview=(
    --preview "$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)"
    --preview-window="$_GIT_FZF_PREVIEW_WINDOW"
  )

  local selected_files
  selected_files=$(__git_fzf_select "$list_files" "${preview[@]}")

  if [ "$selected_files" != "" ]; then
    local git_cmd
    git_cmd="$(__git_cmd_prefix)"
    echo "$git_cmd stash push --include-untracked -- $selected_files"
  fi
}

__git_stash_apply() {
  git-branches stash-apply "${_GIT_FZF_BASE[@]}"
}
