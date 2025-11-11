#!/bin/sh

_GIT_PAGER="\$(git config core.pager || echo cat)"

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

  # Step 5: Open the URL in Google Chrome
  open -a "$BROWSER" "$FINAL_URL"
}

_GIT_FZF_DEFAULT="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
_GIT_FZF_PREVIEW="--preview-window 'right,75%,border-none,wrap'"

__git_fzf_cmd() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local list_cmd="$1"
  local action_cmd="$2"
  local fzf_args="$3"
  local repo_root

  repo_root="$(git rev-parse --show-toplevel)"

  if [ "$fzf_args" != "" ]; then
    fzf_args="$_GIT_FZF_DEFAULT $fzf_args"
  else
    fzf_args="$_GIT_FZF_DEFAULT"
  fi

  (builtin cd "$repo_root" && eval "$list_cmd") |
    eval "fzf $fzf_args" |
    sed "s|^|$repo_root/|" |
    xargs -r sh -c "$action_cmd \"\$@\"" _
}

__git_open_all() {
  local list_files="git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" \"$EDITOR\" "$preview"
}

__git_open_unstaged() {
  local list_files="git ls-files --others --exclude-standard --modified"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" \"$EDITOR\" "$preview"
}

__git_open_staged() {
  local list_files="git diff --name-only --cached"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" \"$EDITOR\" "$preview"
}

__git_unstage() {
  local list_files="git diff --name-only --cached"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "git restore --staged --" "$preview"
}

__git_discard() {
  local list_files="git diff --name-only"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "git checkout --" "$preview"
}

__git_untrack() {
  local list_files="git diff --name-only --cached"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "git rm --cached --" "$preview"
}

__git_rm_untracked() {
  local list_files="git ls-files --others --exclude-standard"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && ls -la -- {}' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "rm --" "$preview"
}

__git_ignore() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1
  
  local action="${1:-open}"
  local cmd
  
  case "$action" in
    open)
      cmd="$EDITOR"
      ;;
    remove|rm)
      cmd="rm --"
      ;;
    *)
      echo "Usage: __git_ignore [open|remove]"
      return 1
      ;;
  esac
  
  local list_files="git status --ignored --porcelain | grep '^!!' | cut -c4-"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && ls -la -- {}' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "$cmd" "$preview"
}

__git_diff() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1

  local list_files="{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq"
  local repo_root="$(git rev-parse --show-toplevel)"
  local is_tracked="cd \"$repo_root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local tracked_diff="cd \"$repo_root\" && git diff --color=always {} | $_GIT_PAGER"
  local untracked_diff="cd \"$repo_root\" && git diff --no-index --color=always /dev/null {} | $_GIT_PAGER"
  local preview_cmd="if $is_tracked; then $tracked_diff; else $untracked_diff; fi"
  local preview="--preview '$preview_cmd' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" \"$EDITOR\" "$preview"
}

__git_reset_soft() {
  local list_commits="git log --oneline"
  local preview="--preview 'git show --color=always {1}' $_GIT_FZF_PREVIEW"
  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  local commit
  commit=$(eval "$list_commits" | eval "fzf $fzf_args $preview" | awk '{print $1}')

  if [ -n "$commit" ]; then
    git reset --soft "$commit"^
  fi
}

__git_open_commits() {
  local list_commits="git log --oneline"
  local preview="--preview 'git show --color=always {1}' $_GIT_FZF_PREVIEW"
  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path --bind='ctrl-a:select-all'"
  commits=$(eval "$list_commits" | eval "fzf $fzf_args $preview" | awk '{print $1}')

  if [ -n "$commits" ]; then
    echo "$commits" | xargs git show --name-only --pretty=format: | sort -u | grep -v '^$' | xargs \"$EDITOR\"
  fi
}

__git_install_lefthook() {
  cat > lefthook.yml << 'EOF'
remotes:
  - git_url: https://github.com/Runeword/lefthook
    configs:
      - precommit-auto-msg.yml
EOF
  lefthook install
}

__git_info() {
  echo "Name:"
  git config user.name
  echo
  echo "Email:"
  git config user.email
  echo
  echo "Remotes:"
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
  selected_branches=$(eval "$list_branches" | eval "fzf $fzf_args $preview")

  if [ -z "$selected_branches" ]; then
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
  __git_fzf_cmd "$list_files" "\"$EDITOR\"" "$files_preview"
}

__git_worktree_add() {
  local checked_out_branches
  checked_out_branches=$(git worktree list | awk '{print $3}' | sed 's/\[//;s/\]//')

  local list_branches="git branch --all --format='%(refname:short)' | grep -v '^HEAD'"

  if [ -n "$checked_out_branches" ]; then
    while IFS= read -r branch; do
      list_branches="$list_branches | grep -v '^$branch\$'"
    done <<EOF
$checked_out_branches
EOF
  fi

  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
  local preview="--preview 'git log --oneline --color=always {}' $_GIT_FZF_PREVIEW"

  local branch
  branch=$(eval "$list_branches" | eval "fzf $fzf_args $preview")

  if [ -n "$branch" ]; then
    local repo_name
    repo_name=$(basename "$(git worktree list | head -n 1 | awk '{print $1}')")

    local next_num=1
    while [ -d "../${repo_name}_${next_num}" ]; do
      next_num=$((next_num + 1))
    done

    local worktree_path="../${repo_name}_${next_num}"
    if git worktree add "$worktree_path" "$branch"; then
      builtin cd "$worktree_path"
    fi
  fi
}

__git_worktree_list() {
  local current_dir
  current_dir=$(pwd)

  local list_worktrees="git worktree list | grep -v '^$current_dir ' | awk '{dir=\$1; sub(/.*\//, \"\", dir); print dir \" \" \$2 \" \" \$3 \"\t\" \$1}'"
  local dir_name=$(basename "$current_dir")
  local branch=$(git rev-parse --abbrev-ref HEAD)
  local commit=$(git rev-parse --short HEAD)
  local header="$dir_name $commit [$branch]"
  local fzf_args="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --header=\"$header\" --with-nth=1 --delimiter='\t' --prompt='  '"
  local preview="--preview 'git -C \$(echo {} | awk -F\"\t\" \"{print \\\$2}\") log --oneline --color=always -10' $_GIT_FZF_PREVIEW"

  local worktree
  worktree=$(eval "$list_worktrees" | eval "fzf $fzf_args $preview" | awk -F'\t' '{print $2}')

  if [ -n "$worktree" ]; then
    builtin cd "$worktree"
  fi
}

__git_worktree_remove() {
  local list_worktrees="git worktree list | tail -n +2"
  local fzf_args="--multi --reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --bind='ctrl-a:select-all'"
  local preview="--preview 'git -C \$(echo {} | awk \"{print \\\$1}\") status' $_GIT_FZF_PREVIEW"

  local worktrees
  worktrees=$(eval "$list_worktrees" | eval "fzf $fzf_args $preview" | awk '{print $1}')

  if [ -n "$worktrees" ]; then
    local current_dir
    current_dir=$(pwd)

    local main_worktree
    main_worktree=$(git worktree list | head -n 1 | awk '{print $1}')

    if echo "$worktrees" | grep -q "^$current_dir$"; then
      builtin cd "$main_worktree"
    fi

    echo "$worktrees" | xargs -I {} git worktree remove {}
  fi
}

__git_stash() {
  git rev-parse --is-inside-work-tree >/dev/null || return 1
  
  local list_files="{ git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard; } | sort | uniq"
  local repo_root="$(git rev-parse --show-toplevel)"
  local is_staged="cd \"$repo_root\" && git diff --cached --name-only -- {} | grep -q ."
  local is_tracked="cd \"$repo_root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local staged_diff="cd \"$repo_root\" && git diff --cached --color=always {} | $_GIT_PAGER"
  local tracked_diff="cd \"$repo_root\" && git diff --color=always {} | $_GIT_PAGER"
  local untracked_diff="cd \"$repo_root\" && git diff --no-index --color=always /dev/null {} | $_GIT_PAGER"
  local preview_cmd="if $is_staged; then $staged_diff; elif $is_tracked; then $tracked_diff; else $untracked_diff; fi"
  local preview="--preview '$preview_cmd' $_GIT_FZF_PREVIEW"
  
  local selected_files
  selected_files=$(builtin cd "$repo_root" && eval "$list_files" | eval "fzf $_GIT_FZF_DEFAULT $preview")
  
  if [ -n "$selected_files" ]; then
    builtin cd "$repo_root" && echo "$selected_files" | xargs git stash push --
  fi
}
