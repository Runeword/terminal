#!/bin/sh

# shellcheck disable=SC2016,SC3043
_GIT_PAGER='$(git config core.pager || echo cat)'

__git_clone() {
  local repo_url="${2:-$(wl-paste)}" # Use clipboard content if no URL is provided
  local base_dir="${HOME}/${1}"
  mkdir -p "$base_dir" # Create the base directory if it doesn't exist
  git clone "$repo_url" "$base_dir/$(basename "$repo_url" .git)"
  builtin cd "$base_dir/$(basename "$repo_url" .git)" || return # Change into the cloned directory
}

__git_open_url() {
  # Step 1: Get the remote URL
  local REMOTE_URL
  REMOTE_URL=$(git remote get-url origin)

  # Step 2: Convert SSH URL to HTTPS URL
  local REPO_URL
  REPO_URL=$(echo "$REMOTE_URL" | sed -E 's#git@[^:]+:([^/]+)/([^.]+)\.git#https://github.com/\1/\2#')

  # Step 3: Get the current branch name
  local BRANCH
  BRANCH=$(git rev-parse --abbrev-ref HEAD)

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
  local root
  root="$(git rev-parse --show-toplevel)"
  local check="cd \"$root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local diff="git diff --ignore-space-change --color=always -- {} | $_GIT_PAGER"
  printf '{ %s && %s; }' "$check" "$diff"
}

__git_diff_untracked() {
  local root
  root="$(git rev-parse --show-toplevel)"
  local diff="cd \"$root\" && git diff --ignore-space-change --no-index --color=always /dev/null {} | $_GIT_PAGER"
  printf '{ %s; }' "$diff"
}

__git_diff_staged() {
  local root
  root="$(git rev-parse --show-toplevel)"
  local check="cd \"$root\" && git diff --cached --name-only -- {} | grep -q ."
  local diff="git diff --ignore-space-change --cached --color=always -- {} | $_GIT_PAGER"
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
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} add -- $args"
}

__git_commit() {
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged) || $(__git_diff_tracked) || $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} add -- $args && git commit "
}

__git_unstage() {
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} restore --staged -- $args"
}

__git_discard() {
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_tracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} checkout -- $args"
}

__git_untrack() {
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_staged)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} rm --cached -- $args"
}

__git_rm_untracked() {
  local repo_cdup
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview
  preview="--preview '$_GIT_FZF_PREVIEW_CMD $(__git_diff_untracked)' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git ls-files --others --exclude-standard" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} clean -f -- $args"
}

__git_ignore() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

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

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview '$_GIT_FZF_PREVIEW_CMD cd \"$repo_root\" && ls -la -- {}' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git status --ignored --porcelain | grep '^!!' | cut -c4-" "$preview")
  [ "$args" != "" ] && echo "$cmd $args"
}

__git_diff() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

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
  args=$(git diff-tree --root --no-commit-id --name-only -r "$commit" | sh -c "fzf --print0 $file_fzf_args $file_preview" | tr '\0' '\n' | sed 's/ /\\ /g' | tr '\n' ' ')
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
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local current_dir
  current_dir=$PWD

  local dir_name
  dir_name=$(basename "$current_dir")
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  local commit
  commit=$(git rev-parse --short HEAD)
  local header
  header=$(printf "%s\t%s\t[%s]" "$dir_name" "$commit" "$current_branch")

  local worktree_info
  worktree_info=$(git worktree list)

  local list_branches
  list_branches=$(git-branches worktree)

  local fzf_args="$_GIT_FZF_BASE --header=\"$header\""
  local preview="--preview '$_GIT_FZF_PREVIEW_CMD git diff --color=always $current_branch..{} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local branch
  branch=$(printf '%s\n' "$list_branches" | sh -c "fzf $fzf_args $preview")

  if [ "$branch" != "" ]; then
    local repo_name
    repo_name=$(basename "$(printf '%s\n' "$worktree_info" | head -n 1 | awk '{print $1}')")

    local next_num=1
    while [ -d "../${repo_name}_${next_num}" ]; do
      next_num=$((next_num + 1))
    done

    local worktree_path="../${repo_name}_${next_num}"
    echo "git worktree add '$worktree_path' '$branch' && builtin cd '$worktree_path' "
  fi
}

__git_worktree_remove() {
  local cmd
  cmd=$(eval "git-branches worktree-remove $_GIT_FZF_BASE")
  [ "$cmd" != "" ] && eval "$cmd"
}

__git_merge() {
  eval "git-branches merge $_GIT_FZF_BASE"
}

__git_branch_switch() {
  eval "git-branches switch $_GIT_FZF_BASE --header='switch to branch'"
}

__git_lefthook_pre_commit() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)

  __lefthook_collect_commands() {
    local file="$1"
    [ -f "$file" ] || return
    grep -A 100 "^pre-commit:" "$file" | grep "^    [a-z-]*:" | sed 's/://;s/^    //'
    grep "^ *- " "$file" | sed 's/^ *- //' | while read -r ext_file; do
      case "$ext_file" in
        /*) __lefthook_collect_commands "$ext_file" ;;
        *) __lefthook_collect_commands "$repo_root/$ext_file" ;;
      esac
    done
  }

  local commands_list
  commands_list=$(__lefthook_collect_commands "$repo_root/lefthook.yml" | sort -u)

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

  local commands
  commands=$(echo "$selected" | tr '\n' ',' | sed 's/,$//')

  echo "Running: lefthook run --all-files --commands $commands pre-commit"
  lefthook run --all-files --commands "$commands" pre-commit
}

__git_cherry_pick() {
  eval "git-branches cherry-pick $_GIT_FZF_BASE"
}

__git_stash_push() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

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
      sed 's/ /\\ /g; s/^/  /; s/$/ \\/')
    local git_root
    git_root=$(git rev-parse --show-cdup)
    echo "git -C ${git_root:-.} stash push --include-untracked -- \\"
    echo "${files% \\}"
  fi
}

__git_stash_apply() {
  eval "git-branches stash-apply $_GIT_FZF_BASE"
}
