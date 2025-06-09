#!/bin/sh

__run_alias() {
  local selected

  selected=$(alias \
    | fzf \
      --delimiter='=' \
      --height 70% \
      --reverse \
      --prompt='  ' \
      --no-separator \
      --info=inline:'' \
    | awk -F'=' '{print $2}' | sed "s/^'//;s/'$//") || return 0

    eval "$selected"
}

__aliases() {
  local prefix_char
  local aliases_file

  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      -p|--prefix)
        prefix_char="$2"
        shift 2
        ;;
      -f|--file)
        aliases_file="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local selected_command
  selected_command=$(< "$aliases_file" \
    column \
    --table \
    --separator $'\t' \
    --output-separator $'\u00A0' \
    | fzf -i \
    --with-nth=1,2,3 \
    --print-query \
    --query "^" \
    --exact \
    --nth=1 \
    --no-info \
    --no-separator \
    --delimiter=$'\u00A0' \
    --cycle \
    --no-preview \
    --reverse \
    --no-sort \
    --prompt='  ' \
    --bind 'one:accept,zero:accept,tab:accept' \
    --height 70% \
  )

  if [ $? -eq 0 ]; then
    local last_column=$(echo "$selected_command" | awk -F $'\u00A0' '{ if (NR==2) print $NF }')
    LBUFFER+=$(echo "$selected_command" | awk -F $'\u00A0' '{ if (NR==2) { sub(/[[:space:]]+$/, "", $2); print $2 " " } }')
    
    if [ "$last_column" = "x" ]; then
      zle accept-line
    fi
  elif [ "$selected_command" ]; then
    LBUFFER+=$(echo "$selected_command" | sed -n '1p' | sed 's/[^[:alpha:]]//g')
  fi

  zle autosuggest-fetch

  return 1
}
