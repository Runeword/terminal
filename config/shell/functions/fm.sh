#!/bin/sh

__open_file() {
  # Select file(s) with fzf, if no selection do nothing

  local selected_files
  selected_files=$(
      fd \
        -0 \
        --hidden \
        --strip-cwd-prefix \
        | \
      fzf \
        --read0 \
        --height 70% \
        --border none \
        --prompt='  ' \
        --multi \
        --keep-right \
        --reverse \
        --info=hidden \
        --no-separator \
        --cycle \
        --ansi \
        --header-first \
        --header=''\''exact !not [!]^prefix [!]suffix$' \
        --preview "$OUT/.config/shell/scripts/fm_preview.sh {}" \
        --preview-window right,55%,border-none,~2 \
        --bind='ctrl-c:execute-silent(wl-copy {})' \
        --bind='ctrl-a:select-all' \
        --bind='ctrl-o:execute(nohup setsid cursor {} > /dev/null 2>&1 &)' \
  ) || return 1
  # --scheme=path \
  # fzf-tmux \
  #   -p \
  #   -h 90% \
  #   -w 95% \

  # Check number of selected files
  local num_lines
  num_lines="$(echo "$selected_files" | wc -l)"

  # cd into selected directory
  if [ "$num_lines" -eq 1 ] && [ -d "$selected_files" ]; then
    if ! cd "$selected_files"; then
      echo "Fail: could not change directory to $selected_files"
      return 1
    fi

    # Then write command in history
    [ "$BASH_VERSION" != "" ] && history -s "cd $selected_files"
    [ "$ZSH_VERSION" != "" ] && print -s "cd $selected_files"
  else
    # else open selected files in editor
    if ! echo "$selected_files" | xargs "$EDITOR"; then
      echo "Fail: could not open $selected_files with $EDITOR"
      return 1
    fi

    # Then write command in history
    [ "$BASH_VERSION" != "" ] && history -s "$EDITOR $(echo "$selected_files" | xargs)"
    [ "$ZSH_VERSION" != "" ] && print -s "$EDITOR $(echo "$selected_files" | xargs)"
  fi

  return 0
}

# find -L . \
#   \( -name '.git' \
#   -o -name 'flake-inputs' \
#   -o -name '.nix-defexpr' \
#   -o -name '.nix-profile' \
#   -o -path './.config/figma-linux/Cache' \
#   -o -path './.config/Slack/Cache' \
#   -o -path './.config/Slack/Service Worker' \
#   -o -path './.config/google-chrome' \
#   -o -path './.local/share/navi/cheats' \
#   -o -path './.local/share/containers/storage/overlay' \
#   -o -path './go/pkg' \
#   -o -name '.cache' \
#   -o -name '.tldrc' \
#   -o -name 'node_modules' \
#   -o -path './.local' \
#   -o -name '.direnv' \) \
#   -prune -o -printf '%P\n' 2>/dev/null |
#   tail -n +2 |

__ripgrep() {
  local selections
  selections=$(rg \
    --color always \
    --colors 'path:none' \
    --colors 'line:none' \
    --colors 'match:none' \
    --colors 'line:fg:red' \
    --line-number \
    --no-heading \
    --smart-case "${*:-}" |
    fzf \
      --ansi \
      --multi \
      --keep-right \
      --delimiter : \
      --reverse \
      --border none \
      --prompt='  ' \
      --cycle \
      --info=hidden \
      --height 70% \
      --no-separator \
      --header-first \
      --header='exact !not [!]^prefix [!]suffix$' \
      --preview 'bat --style=plain --color=always {1} --highlight-line {2}' \
      --preview-window 'right,55%,border-none,+{2}+3/3,~3'
  )

  [ -z "$selections" ] && return 0

  # Extract just the file paths and open with nvim
  echo "$selections" | cut -d: -f1 | xargs nvim
}

__mkdir_cd() {
  mkdir --parents --verbose "$1" && cd "$1" || exit
}

# __open_recent() {
# # Create a temporary file
# tempfile=$(mktemp)

# # Run nvim to write old files to the temporary file
# nvim -es -c 'redir! => myfiles | silent oldfiles | redir END | call writefile(split(myfiles, "\n"), "'$tempfile'")' -c 'q'

# # Use fzf to display the contents of the temporary file
# cat "$tempfile" | fzf

# # Clean up the temporary file
# rm "$tempfile"
# }

__open_recent() {
  tempfile=$(mktemp)
  trap 'rm -f "$tempfile"' EXIT

  nvim -es "+redir! > $tempfile" '+oldfiles' '+redir END' '+qall'

  sed -n '/^[[:space:]]*[0-9]*:[[:space:]]*/s/^[[:space:]]*[0-9]*:[[:space:]]*//p' "$tempfile" |

  while IFS= read -r file; do
      # Skip man pages and non-existent files
      case "$file" in
          man:*) continue ;;
      esac
      [ -f "$file" ] && printf '%s\n' "$file"
  done | sort | uniq |
  fzf \
  --reverse \
  --prompt='  ' \
  --no-separator \
  --info=inline:'' \
  --no-scrollbar \
  --height 70% \
  --header-first \
  --header='open recent' | {
      IFS= read -r selected_file
      [ -n "$selected_file" ] && nvim "$selected_file"
  }
}

__rsync() {
  rsync \
    --archive \
    --verbose \
    --stats \
    --human-readable \
    --compress \
    --info=progress2 \
    --exclude 'node_modules' \
    "$@"
  }

# --color "hl:-1:underline,hl+:-1:underline:reverse" \
# --bind 'enter:become(vim {1} +{2})'
# "cd $(fd --type directory --hidden --follow --no-ignore --exclude .git --exclude node_modules | fzf --inline-info --cycle --preview 'ls -AxF {} | head -$FZF_PREVIEW_LINES' --preview-window right,50%,noborder --no-scrollbar)";
# "cd $(fd --type directory --hidden --follow --no-ignore | fzf --cycle)";
# "xdg-open $(fd --type file --hidden --follow --no-ignore --exclude .git --exclude node_modules | fzf)";
# --info=inline:'' \
