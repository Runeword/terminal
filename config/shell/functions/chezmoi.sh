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

__chezmoi() {
  local operation="$1"
  shift

  if [ $# -gt 0 ]; then
    local selected_files
    selected_files=$*
  else
    local files
    files=$(chezmoi status | awk '{print $2}')
    [ "$files" = "" ] && return 1

    selected_files=$(__select_files "$files" "chezmoi $operation")
    [ "$selected_files" = "" ] && return 1
  fi

  for i in $(echo "$selected_files" | xargs); do
    chezmoi "$operation" "$HOME/$i"
  done
}

__chezmoi_private() {
  local operation="$1"
  shift

  if [ $# -gt 0 ]; then
    local selected_files
    selected_files=$*
  else
    local files
    files=$(chezmoi --source ~/.local/share/chezmoi-private --config ~/.config/chezmoi-private/chezmoi.toml status | awk '{print $2}')
    [ "$files" = "" ] && return 1

    selected_files=$(__select_files "$files" "chezmoi-private $operation" "chezmoi --source ~/.local/share/chezmoi-private --config ~/.config/chezmoi-private/chezmoi.toml")
    [ "$selected_files" = "" ] && return 1
  fi

  for i in $(echo "$selected_files" | xargs); do
    chezmoi --source ~/.local/share/chezmoi-private --config ~/.config/chezmoi-private/chezmoi.toml "$operation" "$HOME/$i"
  done
}

__chezmoi_shared() {
  local operation="$1"
  shift

  if [ $# -gt 0 ]; then
    local selected_files
    selected_files=$*
  else
    local files
    files=$(chezmoi --source ~/.local/share/chezmoi-shared --config ~/.config/chezmoi-shared/chezmoi.toml status | awk '{print $2}')
    [ "$files" = "" ] && return 1

    selected_files=$(__select_files "$files" "chezmoi-shared $operation" "chezmoi --source ~/.local/share/chezmoi-shared --config ~/.config/chezmoi-shared/chezmoi.toml")
    [ "$selected_files" = "" ] && return 1
  fi

  for i in $(echo "$selected_files" | xargs); do
    chezmoi --source ~/.local/share/chezmoi-shared --config ~/.config/chezmoi-shared/chezmoi.toml "$operation" "$HOME/$i"
  done
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

  for i in $(echo "$selected_files" | xargs); do
    chezmoi forget "$HOME/$i"
  done
}
