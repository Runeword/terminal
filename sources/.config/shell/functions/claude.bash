#!/bin/bash
# shellcheck disable=SC2153

__CLAUDE_FZF="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
__CLAUDE_DEFAULT_PLUGINS=(nix-mcp nix-lsp typescript-lsp)

# Prefix that runs claude inside the bubblewrap boundary (scripts/claude-sandbox.bash):
# whole-process filesystem isolation, which Claude Code's own /sandbox can't provide
# here because its seccomp filter blocks AF_UNIX and kills the nix-daemon socket.
# Set CLAUDE_SANDBOX=0 to launch unwrapped.
# macOS gets an empty prefix: bwrap is Linux-only, and Claude Code's own /sandbox
# applies there instead — Seatbelt supports sandbox.allowUnixSockets for the
# nix-daemon socket, which Linux/seccomp cannot (see __claude_provision_darwin_sandbox).
# On Linux the gate fails closed: a missing bwrap or launcher script aborts with a
# message rather than silently starting an unsandboxed claude. bwrap resolves
# against the *interactive* shell's PATH, so packages/linux.nix ships bubblewrap in
# the tools env; CLAUDE_SANDBOX=0 is the explicit escape hatch, not a fallback.
__claude_sandbox_prefix() {
  [ "${CLAUDE_SANDBOX:-1}" = "0" ] && return 0
  [ "$(uname -s)" = "Darwin" ] && return 0
  local script="$PERMEANCE_TREE/.config/shell/scripts/claude-sandbox.bash"
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "claude: bwrap not found on PATH; refusing to launch unsandboxed (CLAUDE_SANDBOX=0 to override)" >&2
    return 1
  fi
  if [ ! -x "$script" ]; then
    echo "claude: $script is missing or not executable; refusing to launch unsandboxed (CLAUDE_SANDBOX=0 to override)" >&2
    return 1
  fi
  # The launcher refuses a cwd that would bind $HOME, an XDG root, or a tree the
  # desktop session executes from. Run the launcher's own gate rather than a copy
  # of it: __claude_run launches via `tmux new-window`, and the launcher's message
  # would land in a pane that clears on death, so the check has to run in the
  # calling shell to be read at all. --check-cwd applies exactly that gate and
  # exits without launching anything.
  "$script" --check-cwd || return 1
  printf '%s ' "$script"
}

# Build __CLAUDE_CMD from __claude_instance, __claude_plugins, __claude_args.
# Fails (and propagates through __claude_init) when the sandbox gate refuses to
# launch, so callers abort after the gate's message instead of silently running.
__claude_build_cmd() {
  local args prefix unlock=""
  prefix=$(__claude_sandbox_prefix) || return 1
  args=$(printf '%q ' "$__claude_args")
  # __claude_run launches via `tmux new-window`, which spawns from the tmux
  # *server's* environment — so a prefix assignment on the caller
  # (CLAUDE_SANDBOX_UNLOCK_SOURCES=1 __claude) is dropped before the sandbox
  # script reads it. Carry it in the command string, like the vars below.
  # CLAUDE_SANDBOX needs no such handling: its gate runs in the calling shell.
  # Every sandbox variable the launcher reads has to be listed here. ALLOW_GH was
  # not, so the documented per-session opt-in did nothing on the normal launch
  # path and the only thing that appeared to work was CLAUDE_SANDBOX=0.
  [ "${CLAUDE_SANDBOX_UNLOCK_SOURCES:-0}" = "1" ] && unlock="${unlock}CLAUDE_SANDBOX_UNLOCK_SOURCES=1 "
  [ "${CLAUDE_SANDBOX_ALLOW_GH:-0}" = "1" ] && unlock="${unlock}CLAUDE_SANDBOX_ALLOW_GH=1 "
  # __CLAUDE_CMD="CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance command claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-4-5-20251101 $args"
  __CLAUDE_CMD="${unlock}CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance ${prefix}claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-5 $args"
}

# Make sources/ own each profile's user-level config: path-scoped rules and bundled
# settings load via the `user` setting source (which the claude wrapper must enable),
# while per-profile state (auth, sessions) stays separate. rules/ is a symlink;
# settings.json is a refreshed copy so Claude's writes can't pollute sources/ or a read-only store.
__claude_provision_config() {
  [ "$PERMEANCE_TREE" != "" ] || return 0
  [ -d "$PERMEANCE_TREE/.claude" ] || return 0
  local dir="$HOME/.claude-$__claude_instance"
  mkdir -p "$dir"
  if [ -d "$PERMEANCE_TREE/.claude/rules" ]; then
    # `ln -sfn` onto a *real directory* does not replace it — it creates the link
    # inside it (rules/rules -> …) and exits 0. So a rules/ directory planted in
    # a profile once survives every later re-provision, for every project, and
    # keeps feeding its own instructions to the model. Anything that is not
    # already a symlink is removed first.
    if [ -e "$dir/rules" ] && [ ! -L "$dir/rules" ]; then
      rm -rf "$dir/rules"
    fi
    ln -sfn "$PERMEANCE_TREE/.claude/rules" "$dir/rules"
  fi
  [ -f "$PERMEANCE_TREE/.claude/settings.json" ] && install -m644 "$PERMEANCE_TREE/.claude/settings.json" "$dir/settings.json"
  __claude_provision_darwin_sandbox "$dir"
}

# macOS gets Claude Code's built-in Seatbelt sandbox rather than the bubblewrap
# launcher, because bubblewrap is Linux-only and, more importantly, Seatbelt can
# allow the nix-daemon socket by path while the Linux seccomp filter cannot
# (anthropics/claude-code#44180). So the Darwin boundary is expressed as settings
# instead of a wrapper. Merged into the provisioned user settings so the shared
# settings.json stays platform-neutral — Linux never sees these keys.
__claude_provision_darwin_sandbox() {
  local dir="$1"
  [ "$(uname -s)" = "Darwin" ] || return 0
  local overlay="$PERMEANCE_TREE/.claude/settings.darwin.json"
  [ -f "$overlay" ] && [ -f "$dir/settings.json" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "claude: jq not found; skipping darwin sandbox overlay" >&2
    return 0
  fi
  local merged
  merged=$(jq -s '.[0] * .[1]' "$dir/settings.json" "$overlay") || {
    echo "claude: failed to merge darwin sandbox overlay" >&2
    return 0
  }
  printf '%s\n' "$merged" >"$dir/settings.json"
}

__claude_init() {
  __claude_instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    __claude_instance="$1"
    shift
  fi
  __claude_args="$*"

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  __claude_plugins=""
  for p in "${__CLAUDE_DEFAULT_PLUGINS[@]}"; do
    [ -d "$plugins_dir/$p" ] && __claude_plugins="$__claude_plugins --plugin-dir $plugins_dir/$p"
  done

  __claude_provision_config
  __claude_build_cmd
}

__claude_init_fzf() {
  __claude_instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    __claude_instance="$1"
    shift
  fi
  __claude_args="$*"

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  local selected
  selected=$(find -L "$plugins_dir" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null | eval fzf --multi "$__CLAUDE_FZF") || return 1
  __claude_plugins=$(echo "$selected" | while IFS= read -r p; do
    [ "$p" != "" ] && printf ' --plugin-dir %s/%s' "$plugins_dir" "$p"
  done)

  __claude_provision_config
  __claude_build_cmd
}

__claude_run() {
  if [ "$TMUX" != "" ]; then
    tmux new-window -a -c "#{pane_current_path}" "$__CLAUDE_CMD"
  else
    eval "$__CLAUDE_CMD"
  fi
}

__claude() {
  __claude_init "$@" || return 0
  __claude_run
}

__claude_plugins() {
  __claude_init_fzf "$@" || return 0
  __claude_run
}

__claude_debug() {
  __claude_init "$@" || return 0

  local file="/tmp/claude-debug.log"
  touch "$file"
  if [ "$TMUX" != "" ]; then
    local script="$PERMEANCE_TREE/.config/tmux/scripts/toggle-pane.sh"
    tmux run-shell "sh $script 50 tail -f $file"
    tmux swap-pane -U \; select-pane -D
  fi
  __CLAUDE_CMD="CLAUDE_CODE_DEBUG_LOG_LEVEL=verbose $__CLAUDE_CMD --debug --debug-file $file"
  eval "$__CLAUDE_CMD"
}
