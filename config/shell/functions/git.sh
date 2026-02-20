#!/bin/sh

# shellcheck disable=SC2016
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

_GIT_FZF_DEFAULT="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
_GIT_FZF_PREVIEW="--preview-window 'right,75%,border-none,wrap'"

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

  (builtin cd "$repo_root" && sh -c "$list_cmd") |
    sh -c "fzf $fzf_args --print0" |
    tr '\0' '\n' | sed 's/ /\\ /g' | tr '\n' ' '
}

__git_open_all() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard" "$preview")
  [ "$args" != "" ] && echo "$EDITOR $args"
}

__git_open_unstaged() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git ls-files --others --exclude-standard --modified" "$preview")
  [ "$args" != "" ] && echo "$EDITOR $args"
}

__git_open_staged() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "$EDITOR $args"
}

__git_unstage() {
  local repo_root repo_cdup
  repo_root="$(git rev-parse --show-toplevel)"
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} restore --staged -- $args"
}

__git_discard() {
  local repo_root repo_cdup
  repo_root="$(git rev-parse --show-toplevel)"
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} checkout -- $args"
}

__git_untrack() {
  local repo_root repo_cdup
  repo_root="$(git rev-parse --show-toplevel)"
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only --cached" "$preview")
  [ "$args" != "" ] && echo "git -C ${repo_cdup:-.} rm --cached -- $args"
}

__git_rm_untracked() {
  local repo_root repo_cdup
  repo_root="$(git rev-parse --show-toplevel)"
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview="--preview 'cd \"$repo_root\" && ls -la -- {}' $_GIT_FZF_PREVIEW"
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
  local preview="--preview 'cd \"$repo_root\" && ls -la -- {}' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git status --ignored --porcelain | grep '^!!' | cut -c4-" "$preview")
  [ "$args" != "" ] && echo "$cmd $args"
}

__git_diff() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local is_tracked="cd \"$repo_root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local tracked_diff="cd \"$repo_root\" && git diff --color=always {} | $_GIT_PAGER"
  local untracked_diff="cd \"$repo_root\" && git diff --no-index --color=always /dev/null {} | $_GIT_PAGER"
  local preview_cmd="if $is_tracked; then $tracked_diff; else $untracked_diff; fi"
  local preview="--preview '$preview_cmd' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq" "$preview")
  [ "$args" != "" ] && echo "$EDITOR $args"
}

__git_reset_soft() {
  local list_commits="git log --oneline --first-parent"
  local preview="--preview 'git show --color=always {1} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  local commit
  commit=$(sh -c "$list_commits" | sh -c "fzf $fzf_args $preview" | awk '{print $1}')

  if [ "$commit" != "" ]; then
    echo "git reset --soft ${commit}^ "
  fi
}

__git_open_commits() {
  local preview="--preview 'git show --color=always {1} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local fzf_args="--multi --reverse --no-separator --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  local commits
  commits=$(git log --oneline | sh -c "fzf $fzf_args $preview" | awk '{print $1}')

  if [ "$commits" != "" ]; then
    local files
    files=$(echo "$commits" | xargs git diff-tree --no-commit-id --name-only -r | sort -u | sed 's/ /\\ /g' | tr '\n' ' ')
    echo "$EDITOR $files"
  fi
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

  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header='select git hooks to install' --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  local preview="--preview 'curl -s https://raw.githubusercontent.com/Runeword/lefthook/main/{}' $_GIT_FZF_PREVIEW"

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

__git_diff_branches() {
  local list_branches="git branch --all --format='%(refname:short)'"
  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
  local preview="--preview 'git log --oneline --color=always {}' $_GIT_FZF_PREVIEW"

  local selected_branches
  selected_branches=$(sh -c "$list_branches" | sh -c "fzf $fzf_args $preview")

  if [ "$selected_branches" = "" ]; then
    echo "Select 1 or 2 branches"
    return 1
  fi

  local branch_count
  branch_count=$(echo "$selected_branches" | wc -l | tr -d ' ')

  local branch1
  local branch2

  if [ "$branch_count" -eq 1 ]; then
    branch1=$(echo "$selected_branches" | sed -n '1p')
    branch2=$(git rev-parse --abbrev-ref HEAD)
  elif [ "$branch_count" -eq 2 ]; then
    branch1=$(echo "$selected_branches" | sed -n '1p')
    branch2=$(echo "$selected_branches" | sed -n '2p')
  else
    echo "Select 1 or 2 branches"
    return 1
  fi

  local list_files
  local repo_root
  list_files="git diff --name-only $branch1 $branch2"
  repo_root="$(git rev-parse --show-toplevel)"

  local files_preview="--preview 'cd \"$repo_root\" && git diff --color=always $branch1 $branch2 -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "$list_files" "$files_preview")
  [ "$args" != "" ] && echo "$EDITOR $args"
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

  local checked_out_branches
  checked_out_branches=$(git worktree list | awk '{print $3}' | sed 's/\[//;s/\]//')

  local list_branches="git branch --all --format='%(refname:short)' | grep -v '^HEAD'"

  if [ "$checked_out_branches" != "" ]; then
    while IFS= read -r branch; do
      list_branches="$list_branches | grep -v '^$branch\$'"
    done <<EOF
"$checked_out_branches"
EOF
  fi

  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header=\"$header\" --prompt='  ' --wrap-sign='' --scheme=path"
  local preview="--preview 'git diff --color=always $current_branch..{} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local branch
  branch=$(sh -c "$list_branches" | sh -c "fzf $fzf_args $preview")

  if [ "$branch" != "" ]; then
    local repo_name
    repo_name=$(basename "$(git worktree list | head -n 1 | awk '{print $1}')")

    local next_num=1
    while [ -d "../${repo_name}_${next_num}" ]; do
      next_num=$((next_num + 1))
    done

    local worktree_path="../${repo_name}_${next_num}"
    echo "git worktree add '$worktree_path' '$branch' && builtin cd '$worktree_path' "
  fi
}

__git_worktree_remove() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local current_dir
  current_dir=$PWD

  local dir_name
  dir_name=$(basename "$current_dir")
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  local commit
  commit=$(git rev-parse --short HEAD)
  local header
  header=$(printf "%s\t%s\t[%s]" "$dir_name" "$commit" "$branch")

  local list_worktrees="git worktree list | tail -n +2 | awk '{dir=\$1; sub(/.*\//, \"\", dir); print dir \"\t\" \$2 \"\t\" \$3 \"\t\" \$1}'"
  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header=\"$header\" --with-nth=1,2,3 --delimiter='\t' --prompt='  ' --bind='ctrl-a:select-all'"
  local preview="--preview 'git diff --color=always $branch..\$(echo {} | awk -F\"\t\" \"{print \\\$3}\" | sed \"s/\\[//;s/\\]//\") | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local worktrees
  worktrees=$(sh -c "$list_worktrees" | sh -c "fzf $fzf_args $preview" | awk -F'\t' '{print $4}')

  if [ "$worktrees" != "" ]; then
    local main_worktree
    main_worktree=$(git worktree list | head -n 1 | awk '{print $1}')

    if echo "$worktrees" | grep -q "^$current_dir$"; then
      builtin cd "$main_worktree" || return
    fi

    echo "$worktrees" | xargs -I {} git worktree remove {} && ls
  fi
}

__git_stash_push() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local list_files="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  local is_staged="cd \"$repo_root\" && git diff --cached --name-only -- {} | grep -q ."
  local is_tracked="cd \"$repo_root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local staged_diff="cd \"$repo_root\" && git diff --cached --color=always {} | $_GIT_PAGER"
  local tracked_diff="cd \"$repo_root\" && git diff --color=always {} | $_GIT_PAGER"
  local untracked_diff="cd \"$repo_root\" && git diff --no-index --color=always /dev/null {} | $_GIT_PAGER"
  local preview_cmd="if $is_staged; then $staged_diff; elif $is_tracked; then $tracked_diff; else $untracked_diff; fi"
  local preview="--preview '$preview_cmd' $_GIT_FZF_PREVIEW"

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

__git_merge() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  local list_branches="git branch --all --format='%(refname:short)' | grep -v '^HEAD' | grep -v '^$current_branch\$'"
  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header=\"merge into $current_branch\" --prompt='  ' --wrap-sign='' --scheme=path --bind='tab:down,btab:up'"
  local preview="--preview 'git diff --color=always $current_branch...{} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local branch
  branch=$(sh -c "$list_branches" | sh -c "fzf $fzf_args $preview")

  if [ "$branch" != "" ]; then
    echo "git merge $branch "
  fi
}

__git_branch_switch() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  local worktree_list
  worktree_list=$(git --no-pager worktree list)

  local list_branches
  list_branches=$(git branch --all --format='%(refname:short)' | grep -v '^HEAD' | while read -r branch; do
    branch_to_check=$(echo "$branch" | sed 's|^remotes/[^/]*/||')
    worktree_path=$(echo "$worktree_list" | awk -v branch="$branch_to_check" 'match($3, /\[(.*)\]/, m) && m[1] == branch {print $1; exit}')
    if [ "$worktree_path" != "" ]; then
      worktree_name=$(basename "$worktree_path")
      echo "$branch	→ $worktree_name"
    else
      echo "$branch	"
    fi
  done)

  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header=\"switch to branch\" --with-nth=1,2 --delimiter='\t' --prompt='  ' --wrap-sign='' --scheme=path"
  local preview="--preview 'branch=\$(echo {} | cut -f1); git diff --color=always $current_branch..\$branch | $_GIT_PAGER' --preview-window 'right,65%,border-none,wrap'"

  local selected
  selected=$(echo "$list_branches" | sh -c "fzf $fzf_args $preview")
  [ "$selected" = "" ] && return 1

  local branch
  branch=$(echo "$selected" | cut -f1)
  local worktree_display
  worktree_display=$(echo "$selected" | cut -f2 | sed 's/^→ //')
  if [ "$worktree_display" = "" ]; then
    echo "git checkout $branch "
    return
  fi

  local branch_to_check
  branch_to_check=$(echo "$branch" | sed 's|^remotes/[^/]*/||')
  local worktree_path
  worktree_path=$(echo "$worktree_list" | awk -v branch="$branch_to_check" 'match($3, /\[(.*)\]/, m) && m[1] == branch {print $1; exit}')
  echo "builtin cd '$worktree_path' "
}

__git_lefthook_pre_commit() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)

  local commands_list
  commands_list=$(
    {
      [ -f "$repo_root/lefthook.yml" ] && grep -A 100 "^pre-commit:" "$repo_root/lefthook.yml" | grep "^  [a-z-]*:" | sed 's/://;s/^  //'
      [ -d "$repo_root/.git/info/lefthook-remotes" ] && find "$repo_root/.git/info/lefthook-remotes" -name "*.yml" -exec grep -A 100 "^pre-commit:" {} \; | grep "^    [a-z-]*:" | sed 's/://;s/^    //'
    } | sort -u
  )

  if [ "$commands_list" = "" ]; then
    echo "No pre-commit commands found in lefthook config"
    return 1
  fi

  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 40% --info=inline:'' --header-first --header='select commands' --prompt='  ' --bind='ctrl-a:select-all'"

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

__git_stash_unstaged() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local repo_root repo_cdup
  repo_root="$(git rev-parse --show-toplevel)"
  repo_cdup="$(git rev-parse --show-cdup)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  local args
  args=$(__git_fzf_select "git diff --name-only" "$preview")

  if [ "$args" != "" ]; then
    echo "git -C ${repo_cdup:-.} stash push --keep-index -- $args"
  fi
}

__git_stash_apply() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local list_stashes="git stash list"
  local fzf_args="--reverse --no-separator --border none --cycle --height 70% --info=inline:'' --header-first --header='select stash to apply' --prompt='  ' --wrap-sign='' --scheme=path --delimiter=':'"
  local preview="--preview 'git stash show --color=always {1} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local selected_stash
  selected_stash=$(sh -c "$list_stashes" | sh -c "fzf $fzf_args $preview")

  [ "$selected_stash" = "" ] && return

  local stash_name="${selected_stash%%:*}"
  local stash_ref
  stash_ref=$(git rev-parse "$stash_name")

  local file_fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header='select files to apply (ctrl-a: all)' --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  local file_preview="--preview 'git diff --color=always ${stash_ref}^ $stash_ref -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"

  local selected_files
  selected_files=$(git stash show --name-only "$stash_ref" | sh -c "fzf --print0 $file_fzf_args $file_preview")

  if [ "$selected_files" != "" ]; then
    local args
    args=$(printf '%s' "$selected_files" | tr '\0' '\n' | sed 's/ /\\ /g' | tr '\n' ' ')
    echo "git restore --source=$stash_name -- $args&& git status"
  fi
}
