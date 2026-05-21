#!/bin/sh

# shellcheck disable=SC2016,SC3043
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

__git_clone() {
  local repo_url="${2:-$(wl-paste)}" # Use clipboard content if no URL is provided
  local base_dir="${HOME}/${1}"
  mkdir -p "$base_dir" # Create the base directory if it doesn't exist
  git clone "$repo_url" "$base_dir/$(basename "$repo_url" .git)"
  builtin cd "$base_dir/$(basename "$repo_url" .git)" || return # Change into the cloned directory
}

__git_open_url() {
  __git_require_repo || return 1

  # Step 1: Get the remote URL
  local REMOTE_URL
  REMOTE_URL=$(git remote get-url origin)

  # Step 2: Convert SSH URL to HTTPS URL
  local REPO_URL
  REPO_URL=$(echo "$REMOTE_URL" | sed -E 's#git@[^:]+:([^/]+)/([^.]+)\.git#https://github.com/\1/\2#')

  # Step 3: Get the current branch name (or full sha when detached, since
  # GitHub treats the literal string "HEAD" in URLs as a branch name and 404s).
  local BRANCH
  BRANCH=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)

  # Step 4: Construct the final URL to the branch page
  local FINAL_URL
  FINAL_URL="${REPO_URL}/${1:-tree}/${BRANCH}"

  if command -v xdg-open >/dev/null 2>&1; then
    (nohup xdg-open "$FINAL_URL" >/dev/null 2>&1 &)
  elif command -v open >/dev/null 2>&1; then
    open -a "$BROWSER" "$FINAL_URL"
  else
    return 1
  fi
}

_GIT_FZF_BASE="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
_GIT_FZF_MULTI="--multi --bind='ctrl-a:select-all'"
_GIT_FZF_DEFAULT="$_GIT_FZF_BASE $_GIT_FZF_MULTI"
_GIT_FZF_PREVIEW_CMD="echo {};"
_GIT_FZF_PREVIEW="--preview-window 'right,75%,border-none,wrap,~1'"

__git_diff_tracked() {
  local root quoted
  root="$(git rev-parse --show-toplevel)"
  quoted="$(__shell_quote "$root")"
  local check="git -C $quoted ls-files --error-unmatch {} > /dev/null 2>&1"
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

__git_fzf_select() {
  local list_cmd="$1"
  local fzf_args="$2"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"

  if [ "$fzf_args" != "" ]; then
    fzf_args="$_GIT_FZF_DEFAULT $fzf_args"
  else
    fzf_args="$_GIT_FZF_DEFAULT"
  fi

  local result
  result=$( (builtin cd "$repo_root" && sh -c "$list_cmd") | sh -c "fzf $fzf_args --print0")
  [ "$result" = "" ] && return 1
  printf '%s' "$result" | tr '\0' '\n' | sed "s/'/'\\\\''/g; s/.*/'&'/" | tr '\n' ' '
}

__git_add() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} add -- $args"
}

__git_commit() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} add -- $args && git commit "
}

__git_unstage() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} restore --staged -- $args"
}

__git_discard() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} checkout -- $args"
}

__git_untrack() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} rm --cached -- $args"
}

__git_rm_untracked() {
  __git_require_repo || return 1

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git ls-files --others --exclude-standard" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} clean -f -- $args"
}

__git_ignore() {
  __git_require_repo || return 1

  local action="${1:-open}"
  local cmd

  case "$action" in
  open)
    cmd="$EDITOR"
    ;;
  remove | rm)
    cmd="rm --"
    ;;
  *)
    echo "Usage: __git_ignore [open|remove]"
    return 1
    ;;
  esac

  local repo_root quoted_repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  quoted_repo_root="$(__shell_quote "$repo_root")"
  local preview="--preview '$_GIT_FZF_PREVIEW_CMD cd $quoted_repo_root && ls -la -- {}' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git status --ignored --porcelain | grep '^!!' | cut -c4-" "$preview")
  [ "$args" != "" ] && echo "$cmd $args"
}

__git_diff() {
  __git_require_repo || return 1

  local repo_cdup list_cmd preview
  repo_cdup="$(git rev-parse --show-cdup)"

  case "${1:-all}" in
  staged)
    list_cmd="git diff --name-only --cached"
    preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)' $_GIT_FZF_PREVIEW"
    ;;
  unstaged)
    list_cmd="{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq"
    preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
    ;;
  *)
    list_cmd="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
    preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
    ;;
  esac

  local args
  args=$(__git_fzf_select "$list_cmd" "$preview")
  [ "$args" != "" ] && echo "$EDITOR ${repo_cdup:+$repo_cdup}$args"
}

__git_diff_branches() {
  eval "git-branches diff-branches $_GIT_FZF_BASE"
}

__git_reset_soft() {
  __git_require_repo || return 1

  local list_commits="git log --oneline --first-parent"
  local preview="--preview '$_GIT_FZF_PREVIEW_CMD git show --color=always --decorate {1} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local fzf_args="$_GIT_FZF_BASE"
  local commit
  commit=$(sh -c "$list_commits" | sh -c "fzf $fzf_args $preview" | awk '{print $1}')

  if [ "$commit" != "" ]; then
    local offset
    offset=$(git rev-list --count --first-parent "$commit"..HEAD)
    echo "git reset --soft HEAD~$((offset + 1)) "
  fi
}

__git_log() {
  __git_require_repo || return 1

  local preview="--preview '$_GIT_FZF_PREVIEW_CMD git show --color=always --decorate {1} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local fzf_args="$_GIT_FZF_BASE"
  local commit
  commit=$(git log --oneline | sh -c "fzf $fzf_args $preview" | awk '{print $1}')

  [ "$commit" = "" ] && return

  local file_fzf_args="$_GIT_FZF_DEFAULT --header='select files to open'"
  local file_preview="--preview '$_GIT_FZF_PREVIEW_CMD git show --color=always $commit -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local args
  args=$(git diff-tree --root --no-commit-id --name-only -r "$commit" | sh -c "fzf --print0 $file_fzf_args $file_preview" | tr '\0' '\n' | sed "s/'/'\\\\''/g; s/.*/'&'/" | tr '\n' ' ')
  [ "$args" != "" ] && echo "$EDITOR ${repo_cdup:+$repo_cdup}$args"
}

__git_install_lefthook() {
  local repo_url="https://github.com/Runeword/lefthook"
  local api_url="https://api.github.com/repos/Runeword/lefthook/contents"

  local available_configs
  available_configs=$(curl -s "$api_url" | grep -o '"name": "[^"]*\.yml"' | grep -v '"name": "lefthook.yml"' | cut -d'"' -f4)

  if [ "$available_configs" = "" ]; then
    echo "Failed to fetch available configs from repository"
    return 1
  fi

  local fzf_args="$_GIT_FZF_DEFAULT --header='select git hooks to install'"
  local preview="--preview '$_GIT_FZF_PREVIEW_CMD curl -s https://raw.githubusercontent.com/Runeword/lefthook/main/{}' $_GIT_FZF_PREVIEW"

  local selected_configs
  selected_configs=$(echo "$available_configs" | sh -c "fzf $fzf_args $preview")

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
  eval "git-branches worktree-add $_GIT_FZF_BASE"
}

__git_worktree_remove() {
  eval "git-branches worktree-remove $_GIT_FZF_BASE"
}

__git_merge() {
  eval "git-branches merge $_GIT_FZF_BASE"
}

__git_branch_switch() {
  eval "git-branches switch $_GIT_FZF_BASE --header='switch to branch'"
}

# Emit each pre-commit command name from a lefthook YAML, one per line, and
# recurse into files listed under a top-level `extends:` key. The recursion is
# scoped to that key only — without it, any YAML list item anywhere in the
# file (a command's `tags:` list, a file glob, …) would be treated as an
# include path. Defined at top level so it doesn't leak into the global
# namespace as a side effect of running __git_lefthook_pre_commit.
__lefthook_collect_commands() {
  local file="$1"
  local repo_root="$2"
  [ -f "$file" ] || return

  grep -A 100 "^pre-commit:" "$file" | grep "^    [a-z-]*:" | sed 's/://;s/^    //'

  awk '
    /^extends:/ { in_extends = 1; next }
    in_extends && /^[^ #\t]/ { in_extends = 0 }
    in_extends && /^[ \t]+- / { print }
  ' "$file" | sed 's/^ *- //' | while read -r ext_file; do
    case "$ext_file" in
    /*) __lefthook_collect_commands "$ext_file" "$repo_root" ;;
    *) __lefthook_collect_commands "$repo_root/$ext_file" "$repo_root" ;;
    esac
  done
}

__git_lefthook_pre_commit() {
  __git_require_repo || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)

  local commands_list
  commands_list=$(__lefthook_collect_commands "$repo_root/lefthook.yml" "$repo_root" | sort -u)

  if [ "$commands_list" = "" ]; then
    echo "No pre-commit commands found in lefthook config"
    return 1
  fi

  local fzf_args="$_GIT_FZF_DEFAULT --height 40% --header='select commands'"

  local selected
  selected=$(echo "$commands_list" | sh -c "fzf $fzf_args")

  if [ "$selected" = "" ]; then
    echo "No commands selected"
    return 0
  fi

  local command_flags
  command_flags=$(echo "$selected" | sed 's/^/--command /' | tr '\n' ' ')

  echo "Running: lefthook run --all-files ${command_flags}pre-commit"
  eval "lefthook run --all-files ${command_flags}pre-commit"
}

__git_cherry_pick() {
  eval "git-branches cherry-pick $_GIT_FZF_BASE"
}

__git_stash_push() {
  __git_require_repo || return 1

  local list_files="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"

  local selected_files
  selected_files=$(builtin cd "$repo_root" && sh -c "$list_files" | sh -c "fzf $_GIT_FZF_DEFAULT --print0 $preview")

  if [ "$selected_files" != "" ]; then
    local files
    files=$(printf '%s' "$selected_files" | tr '\0' '\n' |
      sed "s/'/'\\\\''/g; s/.*/  '&' \\\\/")
    local git_root
    git_root=$(git rev-parse --show-cdup)
    echo "git -C ${git_root:-.} stash push --include-untracked -- \\"
    echo "${files% \\}"
  fi
}

__git_stash_apply() {
  eval "git-branches stash-apply $_GIT_FZF_BASE"
}
