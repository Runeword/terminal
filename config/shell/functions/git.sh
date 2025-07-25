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

# Generic fzf git action: $1 = list command, $2... = action command
__git_fzf_action() {
  local list_cmd="$1"
  shift
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  (cd "$repo_root" && eval "$list_cmd") |
    fzf \
      --multi --reverse --no-separator --border none --cycle --height 70% \
      --info=inline:'' \
      --header-first \
      --prompt='  ' \
      --scheme=path \
      --bind='ctrl-a:select-all' |
    xargs -r "$@"
}

# Wrappers for specific use cases
__git_open_all() {
  __git_fzf_action "git diff --name-only; git diff --name-only --cached; git ls-files --others --exclude-standard" nvim
}

__git_open_unstaged() {
  __git_fzf_action "git ls-files --others --exclude-standard --modified" nvim
}

__git_open_staged() {
  __git_fzf_action "git diff --name-only --cached" nvim
}

__git_unstage() {
  __git_fzf_action "git diff --name-only --cached" git restore --staged --
}

__git_discard() {
  __git_fzf_action "git diff --name-only" git checkout --
}

__git_untrack() {
  __git_fzf_action "git diff --name-only --cached" git rm --cached --
}
