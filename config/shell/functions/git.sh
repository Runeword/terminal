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
  __git_fzf_cmd "$list_files" nvim "$preview"
}

__git_open_unstaged() {
  local list_files="git ls-files --others --exclude-standard --modified"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" nvim "$preview"
}

__git_open_staged() {
  local list_files="git diff --name-only --cached"
  local repo_root="$(git rev-parse --show-toplevel)"
  local preview="--preview 'cd \"$repo_root\" && git diff --cached --color=always -- {} | $_GIT_PAGER' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" nvim "$preview"
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

__git_diff() {
  local list_files="{ git diff --name-only; git ls-files --others --exclude-standard; } | sort | uniq"
  local repo_root="$(git rev-parse --show-toplevel)"
  local is_tracked="cd \"$repo_root\" && git ls-files --error-unmatch {} > /dev/null 2>&1"
  local tracked_diff="cd \"$repo_root\" && git diff --color=always {} | $_GIT_PAGER"
  local untracked_diff="cd \"$repo_root\" && git diff --no-index --color=always /dev/null {} | $_GIT_PAGER"
  local preview_cmd="if $is_tracked; then $tracked_diff; else $untracked_diff; fi"
  local preview="--preview '$preview_cmd' $_GIT_FZF_PREVIEW"
  __git_fzf_cmd "$list_files" "echo" "$preview"
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
  echo "User Name: $(git config user.name)"
  echo "User Email: $(git config user.email)"
  echo "Remotes:"
  git remote -v
}

__git_set_user() {
  git config user.name "Runeword"
  git config user.email "60324746+Runeword@users.noreply.github.com"
}
