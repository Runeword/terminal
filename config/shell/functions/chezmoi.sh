#!/bin/sh

__select_files() {
  local files="$1"
  local header="$2"
  local chezmoi_cmd="${3:-chezmoi}"

  echo "$files" | fzf \
    --multi --reverse --no-separator --border none --cycle --height 100% \
    --info=inline:'' \
    --header-first \
    --prompt='  ' \
    --scheme=path \
    --header="$header" \
    --bind='ctrl-a:select-all' \
    --preview "$chezmoi_cmd diff --reverse --color=true ~/{}" \
    --preview-window bottom,80%,noborder
}

__chezmoi_operation() {
  local operation="$1"
  local label="$2"
  shift 2

  local chezmoi_args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    chezmoi_args+=("$1")
    shift
  done
  [ "$1" = "--" ] && shift

  if [ $# -gt 0 ]; then
    local selected_files
    selected_files=$*
  else
    local files
    files=$(chezmoi "${chezmoi_args[@]}" status | awk '{print $2}')
    [ "$files" = "" ] && return 1

    selected_files=$(__select_files "$files" "$label $operation" "chezmoi ${chezmoi_args[*]}")
    [ "$selected_files" = "" ] && return 1
  fi

  echo "$selected_files" | xargs | while read -r i; do
    chezmoi "${chezmoi_args[@]}" "$operation" "$HOME/$i"
  done
}

__chezmoi() {
  local operation="$1"
  shift
  __chezmoi_operation "$operation" "chezmoi" -- "$@"
}

__chezmoi_private() {
  local operation="$1"
  shift
  __chezmoi_operation "$operation" "chezmoi-private" --source ~/.local/share/chezmoi-private --config ~/.config/chezmoi-private/chezmoi.toml -- "$@"
}

__chezmoi_shared() {
  local operation="$1"
  shift
  __chezmoi_operation "$operation" "chezmoi-shared" --source ~/.local/share/chezmoi-shared --config ~/.config/chezmoi-shared/chezmoi.toml -- "$@"
}

__chezmoi_status() {
  local files
  files=$(chezmoi status | awk '{print $2}')
  [ "$files" = "" ] && return 1

  local selected_files
  selected_files=$(__select_files "$files")
  [ "$selected_files" = "" ] && return 1

  echo "$selected_files" | xargs "$EDITOR"
}

__chezmoi_cd() {
  cd "$(chezmoi source-path)" || exit
}

__chezmoi_managed() {
  local files
  files=$(chezmoi managed --include=files)
  [ "$files" = "" ] && return 1

  local selected_files
  selected_files=$(echo "$files" | fzf \
    --multi --reverse --no-separator --border none --cycle --height 70% \
    --info=inline:'' \
    --header-first \
    --prompt='  ' \
    --scheme=path \
    --header="chezmoi managed --include=files" \
    --bind='ctrl-a:select-all' \
    --preview 'bat --style=plain --color=always {}' \
    --preview-window right,70%,noborder)
  [ "$selected_files" = "" ] && return 1

  echo "$selected_files" | xargs "$EDITOR"
}

__chezmoi_forget() {
  if [ $# -gt 0 ]; then
    local selected_files
    selected_files=$*
  else
    local files
    files=$(chezmoi managed --include=files)
    [ "$files" = "" ] && return 1

    selected_files=$(echo "$files" | fzf \
      --multi --reverse --no-separator --border none --cycle --height 70% \
      --info=inline:'' \
      --header-first \
      --prompt='  ' \
      --scheme=path \
      --header="chezmoi forget" \
      --bind='ctrl-a:select-all' \
      --preview 'bat --style=plain --color=always {}' \
      --preview-window right,70%,noborder)
    [ "$selected_files" = "" ] && return 1
  fi

  # "$(echo "$selected_files" | xargs)" | while IFS= read -r i; do chezmoi forget "$HOME/$i"; done

  echo "$selected_files" | xargs | while read -r i; do
    chezmoi forget "$HOME/$i"
  done
}
