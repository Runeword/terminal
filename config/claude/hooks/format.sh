#!/bin/sh
file=$(jq -r '.tool_input.file_path')
[ -f "$file" ] || exit 0
case "$file" in
  *.go) gofmt -w "$file" ;;
  *.nix) nixfmt "$file" ;;
  *.sh) shfmt -w "$file" ;;
  *.toml) taplo fmt "$file" ;;
esac
