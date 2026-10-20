#!/bin/bash

# fzf layout of the gcloud pickers (mirrors aws.bash) — array form so values
# with spaces or quotes round-trip through "${arr[@]}" without re-parsing.
_GCLOUD_FZF=(
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

# Pick one of the account's projects with fzf and make it the active
# configuration's project: the one gcloud commands default to, which the
# prompt shows.
__gcloud_project_set() {
  local projects selected
  projects=$(gcloud projects list --format='value(projectId)' --sort-by=projectId) || return 1
  [ "$projects" = "" ] && return 1

  selected=$(echo "$projects" | fzf "${_GCLOUD_FZF[@]}") || return 0
  [ "$selected" = "" ] && return 1

  gcloud config set project "$selected"
}

# Adds a version to the secret named $1. The value is read without echo and
# reaches gcloud on stdin, so it never shows on the command line or in the
# shell history.
__gcloud_secret_set() {
  local value
  printf 'value: ' >&2
  IFS= read -rs value || return
  echo >&2
  printf %s "$value" | gcloud secrets versions add "$1" --data-file=-
}
