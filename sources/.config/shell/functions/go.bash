#!/bin/bash

# Dev builds of the Go programs under packages: one module per directory,
# directly under it (fm-query) or one group down (git/branches), each binary
# named after its go.mod module (git-branches), not its directory. They go to
# .direnv/bin, which direnv puts on PATH ahead of the Nix-built copies inside
# ~/terminal, so a dev build shadows its Nix copy for as long as it exists: gow
# removes them when it stops, godc on demand. Claude's status line and hooks
# never see them: the claude wrapper puts its Nix-built copies first on its PATH,
# so those need a terminal rebuild.

# Prints the sh program god and gow build with ($1 packages, $2 the bin
# dir): every module, or with WATCHEXEC_COMMON_PATH set (gow, on save) only the
# module holding that path, found by walking up to the nearest go.mod.
__go_dev_builder() {
  cat <<'EOF'
src=$1
bin=$2
build() {
  name=$(awk '$1 == "module" { print $2; exit }' "$src/$1/go.mod")
  name=${name##*/}
  if out=$(cd "$src/$1" && go build -o "$bin/$name" . 2>&1); then
    printf "\033[32m✓\033[0m %s\n" "$name"
  else
    printf "\033[31m✗ %s\033[0m\n%s\n" "$name" "$out"
  fi
}
m=""
case "${WATCHEXEC_COMMON_PATH:-}" in
  *"$src"/*) m=${WATCHEXEC_COMMON_PATH##*"$src"/} ;;
esac
while [ -n "$m" ] && [ ! -f "$src/$m/go.mod" ]; do
  case $m in */*) m=${m%/*} ;; *) m="" ;; esac
done
if [ -n "$m" ]; then
  build "$m"
else
  for g in "$src"/*/go.mod "$src"/*/*/go.mod; do
    [ -f "$g" ] || continue
    d=${g%/go.mod}
    build "${d#"$src"/}"
  done
fi
EOF
}

# Removes the dev builds. Every compiled binary in .direnv/bin is one (nix-direnv
# only writes its nix-direnv-reload script there), so this also catches builds of
# modules since renamed or deleted, which a module list would miss.
__go_dev_clean() {
  local bin="$HOME/terminal/.direnv/bin" f removed=""
  while IFS= read -r f; do
    if [ "$(head -c 4 "$f")" = $'\177ELF' ]; then
      rm -f "$f" && removed="$removed ${f##*/}"
    fi
  done < <(find "$bin" -maxdepth 1 -type f 2>/dev/null)
  if [ -n "$removed" ]; then
    printf 'Removed dev builds:%s\n' "$removed"
  else
    printf 'No dev builds in %s\n' "$bin"
  fi
}

# Builds every module once (`god`), or removes the builds (`godc`, god clean).
__go_dev() {
  local src="$HOME/terminal/packages"
  local bin="$HOME/terminal/.direnv/bin"

  if [ "$1" = "clean" ]; then
    __go_dev_clean
  else
    mkdir -p "$bin" || return 1
    sh -c "$(__go_dev_builder)" _ "$src" "$bin"
  fi
  # Look commands up again: both shells keep running an already-hashed Nix copy
  # over a new dev build, and bash keeps running a removed one.
  hash -r
}

# Live-rebuild every Go program under packages into .direnv/bin. Uses
# watchexec (event-driven): builds them all on startup, then rebuilds only the
# module whose .go file changed. Ctrl-C stops it and removes the builds. Bound to
# the `gow` leader entry.
__go_watch() {
  local src="$HOME/terminal/packages"
  local bin="$HOME/terminal/.direnv/bin"

  if ! command -v watchexec >/dev/null 2>&1; then
    printf 'gow: watchexec not on PATH — rebuild the terminal so packages.tools is current\n' >&2
    return 1
  fi
  if ! mkdir -p "$bin"; then
    printf 'gow: cannot write %s — is .direnv writable? (run direnv allow)\n' "$bin" >&2
    return 1
  fi

  printf '\033[2J\033[H── go watch · packages → .direnv/bin (Ctrl-C to stop) ──\n'
  # watchexec runs the builder once on startup (no change info -> build all), then
  # on each save with WATCHEXEC_COMMON_PATH set to the changed path. -n runs the
  # command with no shell wrapping; --emit-events-to sets that env var. SIGHUP is
  # only an event to watchexec and it misses its terminal closing, so it would
  # outlive the pane: cat exits when the pane closes, and --stdin-quit stops
  # watchexec on the EOF that leaves on the pipe (Ctrl-D does the same).
  # The subshell outlives the Ctrl-C that stops watchexec, to remove the builds on
  # the way out; its HUP trap removes them when the pane closes.
  (
    trap : INT
    trap '__go_dev_clean >/dev/null 2>&1; exit' HUP TERM
    cat | watchexec \
      --watch "$src" --exts go --emit-events-to=environment -n \
      --restart --debounce 200ms --quiet --stdin-quit \
      -- sh -c "$(__go_dev_builder)" _ "$src" "$bin"
    __go_dev_clean
  )
  hash -r # see __go_dev
}
