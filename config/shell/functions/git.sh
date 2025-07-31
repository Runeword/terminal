#!/bin/sh

__git_clone() {
  local repo_url="${2:-$(wl-paste)}" # Use clipboard content if no URL is provided
  local base_dir="${HOME}/${1}"
  mkdir -p "$base_dir" # Create the base directory if it doesn't exist
  git clone "$repo_url" "$base_dir/$(basename "$repo_url" .git)"
  cd "$base_dir/$(basename "$repo_url" .git)" || return # Change into the cloned directory
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

__git_fzf_cmd() {
  local list_cmd="$1"
  local action_cmd="$2"
  local fzf_args="$3"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  
  local default_args="--multi --reverse --no-separator --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --scheme=path --bind='ctrl-a:select-all'"
  
  if [[ -n "$fzf_args" ]]; then
    fzf_args="$default_args $fzf_args"
  else
    fzf_args="$default_args"
  fi
  
  (cd "$repo_root" && eval "$list_cmd") |
    eval "fzf $fzf_args" |
    xargs -r -I {} sh -c "cd '$repo_root' && $action_cmd {}"
}

__git_open_all() {
  __git_fzf_cmd "git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard" nvim "--preview 'git diff --color=always -- {}' --preview-window 'right,75%,border-none'"
}

__git_open_unstaged() {
  __git_fzf_cmd "git ls-files --others --exclude-standard --modified" nvim "--preview 'git diff --color=always -- {}' --preview-window 'right,75%,border-none'"
}

__git_open_staged() {
  __git_fzf_cmd "git diff --name-only --cached" nvim "--preview 'git diff --cached --color=always -- {}' --preview-window 'right,75%,border-none'"
}

__git_unstage() {
  __git_fzf_cmd "git diff --name-only --cached" "git restore --staged --" "--preview 'git diff --cached --color=always -- {}' --preview-window 'right,75%,border-none'"
}

__git_discard() {
  __git_fzf_cmd "git diff --name-only" "git checkout --" "--preview 'git diff --color=always -- {}' --preview-window 'right,75%,border-none'"
}

__git_untrack() {
  __git_fzf_cmd "git diff --name-only --cached" "git rm --cached --" "--preview 'git diff --cached --color=always -- {}' --preview-window 'right,75%,border-none'"
}
