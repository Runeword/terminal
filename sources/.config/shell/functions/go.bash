#!/bin/bash

__go_dev() {
  local src="$HOME/terminal/packages/custom"
  local bin="$HOME/terminal/.direnv/bin"

  if [ "$1" = "clean" ]; then
    rm -f "$bin/git-branches" "$bin/claude-statusline"
    echo "Cleaned dev builds. Falling back to Nix store:"
    echo "  $(which git-branches)"
    echo "  claude-statusline (via Claude wrapper PATH)"
    return
  fi

  mkdir -p "$bin"
  (builtin cd "$src/git-branches" && go build -o "$bin/git-branches" .)
  (builtin cd "$src/claude-statusline" && go build -o "$bin/claude-statusline" .)
  echo "Built: $bin/git-branches $bin/claude-statusline"
}

# Live-rebuild every Go program under packages/custom into .direnv/bin (which is
# on PATH, so the running terminal / Claude picks up the fresh binary). Uses
# watchexec (event-driven): builds them all on startup, then rebuilds only the
# module whose .go file changed. Ctrl-C to stop. Bound to the `gow` leader entry.
__go_watch() {
  local src="$HOME/terminal/packages/custom"
  local bin="$HOME/terminal/.direnv/bin"

  if ! command -v watchexec >/dev/null 2>&1; then
    printf 'gow: watchexec not on PATH — rebuild the terminal so packages.tools is current\n' >&2
    return 1
  fi
  if ! mkdir -p "$bin"; then
    printf 'gow: cannot write %s — is .direnv writable? (run direnv allow)\n' "$bin" >&2
    return 1
  fi

  printf '\033[2J\033[H── go watch · packages/custom → .direnv/bin (Ctrl-C to stop) ──\n'
  # watchexec runs the builder once on startup (no change info -> build all), then
  # on each save with WATCHEXEC_COMMON_PATH set to the changed module's directory.
  # -n runs the command with no shell wrapping; --emit-events-to sets that env var.
  # shellcheck disable=SC2016  # the sh -c body is single-quoted on purpose
  exec watchexec \
    --watch "$src" --exts go --emit-events-to=environment -n \
    --restart --debounce 200ms --quiet \
    -- sh -c '
      src=$1
      bin=$2
      build() {
        if out=$(cd "$src/$1" && go build -o "$bin/$1" . 2>&1); then
          printf "\033[32m✓\033[0m %s\n" "$1"
        else
          printf "\033[31m✗ %s\033[0m\n%s\n" "$1" "$out"
        fi
      }
      m=""
      case "${WATCHEXEC_COMMON_PATH:-}" in
        *"$src"/*) m=${WATCHEXEC_COMMON_PATH##*"$src"/}; m=${m%%/*} ;;
      esac
      if [ -n "$m" ] && [ -f "$src/$m/go.mod" ]; then
        build "$m"
      else
        for g in "$src"/*/go.mod; do d=${g%/go.mod}; build "${d##*/}"; done
      fi
    ' _ "$src" "$bin"
}
