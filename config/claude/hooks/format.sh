#!/bin/sh

file=$(jq -r '.tool_input.file_path')

[ -f "$file" ] || exit 0

case "$file" in
  *.nix)
    nixfmt "$file"
    ;;
  *.sh)
    shfmt --write --indent 2 --case-indent --language-dialect posix --simplify "$file"
    shellharden --replace "$file"
    ;;
  *.toml)
    RUST_LOG=warn taplo format --quiet "$file"
    ;;
  *.go)
    gofumpt -w "$file"
    ;;
  *.yml | *.yaml)
    yamlfmt "$file"
    ;;
esac
