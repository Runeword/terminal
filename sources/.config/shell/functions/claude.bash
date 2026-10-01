#!/bin/bash
# shellcheck disable=SC2153

__CLAUDE_FZF="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"
# nix-mcp is opt-in, not a default: the mcp-nixos server costs ~1.7s to import on
# every launch (its own server init, not uvx overhead; no faster version exists),
# so loading it unconditionally taxed every session. Pick it from __claude_plugins
# (the fzf plugin picker) when you need nixpkgs/option search.
__CLAUDE_DEFAULT_PLUGINS=(nix-lsp typescript-lsp)

# Prefix that runs claude inside the bubblewrap boundary: claude-sandbox, from
# github:Runeword/claude-sandbox (on PATH through the tools env). Whole-process
# filesystem isolation, which Claude Code's own /sandbox can't provide here
# because its seccomp filter blocks AF_UNIX and kills the nix-daemon socket.
# Set CLAUDE_SANDBOX=0 to launch unwrapped.
# macOS gets no bwrap prefix: bwrap is Linux-only, and Claude Code's own /sandbox
# applies there instead — Seatbelt supports sandbox.allowUnixSockets for the
# nix-daemon socket, which Linux/seccomp cannot (see __claude_provision_sandbox_overlay).
# Only a session that opts into a credential gets a launcher there (see
# __claude_macos_prefix).
# On Linux the gate fails closed: a missing bwrap or launcher script aborts with a
# message rather than silently starting an unsandboxed claude. bwrap resolves
# against the *interactive* shell's PATH, so packages/linux.nix ships bubblewrap in
# the tools env; CLAUDE_SANDBOX=0 is the explicit escape hatch, not a fallback.
__claude_sandbox_prefix() {
  [ "${CLAUDE_SANDBOX:-1}" = "0" ] && return 0
  if [ "$(uname -s)" = "Darwin" ]; then
    __claude_macos_prefix
    return
  fi
  local script
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "claude: bwrap not found on PATH; refusing to launch unsandboxed (CLAUDE_SANDBOX=0 to override)" >&2
    return 1
  fi
  # The launcher applies a seccomp filter (from claude-seccomp-bpf) that stops the
  # namespace injecting characters into this terminal (TIOCSTI, CVE-2017-5226), and
  # fails closed without it. Pre-check it here, in the calling shell, so a missing
  # binary is reported where it can be read — the launcher's own refusal would land
  # in the `tmux new-window` pane, which clears the moment it dies. Same rationale
  # as the bwrap pre-check above and the --check-cwd gate below.
  if ! command -v claude-seccomp-bpf >/dev/null 2>&1; then
    echo "claude: claude-seccomp-bpf not found on PATH; it emits the TIOCSTI seccomp filter the sandbox needs and the launcher fails closed without it. Refusing to launch — rebuild the terminal to pick it up, or CLAUDE_SANDBOX=0 to override." >&2
    return 1
  fi
  # cf/cj sessions run behind claude-egress-proxy's network filter, and the
  # launcher refuses them without it: pre-checked here for the same reason.
  if { [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ] || [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = "1" ]; } &&
    ! command -v claude-egress-proxy >/dev/null 2>&1; then
    echo "claude: claude-egress-proxy not found on PATH; cf/cj sessions run behind its network filter, and the launcher refuses them without it. Rebuild the terminal to pick it up, or launch without the credential." >&2
    return 1
  fi
  # Resolved here and handed on as a full path: the command runs in a
  # `tmux new-window` pane, which gets the tmux server's PATH, not this one.
  if ! script=$(command -v claude-sandbox); then
    echo "claude: claude-sandbox not found on PATH; refusing to launch unsandboxed. Rebuild the terminal to pick it up, or CLAUDE_SANDBOX=0 to override." >&2
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

# macOS has no bwrap launcher, but the per-session credential opt-ins
# (CLAUDE_SANDBOX_ALLOW_FIREBASE, CLAUDE_SANDBOX_ALLOW_JIRA) still need one:
# claude-macos (github:Runeword/claude-sandbox) reads the credential from pass
# on the host and hands it to claude. Only a session that opts in goes through
# it; every other launch runs claude directly, as before. Like the Linux gate, a
# missing launcher refuses the launch rather than starting without what was
# asked for.
__claude_macos_prefix() {
  [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ] || [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = "1" ] || return 0
  local script
  if ! script=$(command -v claude-macos); then
    echo "claude: claude-macos not found on PATH; refusing to launch without the credentials CLAUDE_SANDBOX_ALLOW_* asked for. Rebuild the terminal to pick it up." >&2
    return 1
  fi
  printf '%s ' "$script"
}

# Build __CLAUDE_CMD from __claude_instance, __claude_plugins, __claude_args.
# __CLAUDE_CMD is a string that tmux new-window or eval parses again, so
# __claude_init keeps __claude_args shell-quoted, one word per argument: an
# option's value (--resume <id>, --model <name>) stays a word of its own.
# Fails (and propagates through __claude_init) when the sandbox gate refuses to
# launch, so callers abort after the gate's message instead of silently running.
__claude_build_cmd() {
  local prefix flags="" secrets=""
  prefix=$(__claude_sandbox_prefix) || return 1
  # __claude_run launches via `tmux new-window`, which spawns from the tmux
  # *server's* environment — so a prefix assignment on the caller
  # (CLAUDE_SANDBOX_ALLOW_GH=1 __claude) is dropped before the sandbox
  # script reads it. Carry it in the command string, like the vars below.
  # CLAUDE_SANDBOX needs no such handling: its gate runs in the calling shell.
  # Every sandbox variable the launcher reads has to be listed here. ALLOW_GH was
  # not, so the documented per-session opt-in did nothing on the normal launch
  # path and the only thing that appeared to work was CLAUDE_SANDBOX=0.
  [ "${CLAUDE_SANDBOX_ALLOW_GH:-0}" = "1" ] && flags="${flags}CLAUDE_SANDBOX_ALLOW_GH=1 "
  # Firebase: scoped service-account auth. CLAUDE_SANDBOX_ALLOW_FIREBASE=1 makes the
  # launcher mount a least-privilege SA key from `pass` (entry
  # claude/firebase-sa-key) as ADC, with your personal `firebase login` token left
  # masked (see CLAUDE_SANDBOX_ALLOW_FIREBASE in claude-sandbox.bash, or
  # claude-macos.bash on macOS). Only the flag is carried here; the pass read and
  # the bind happen in the launcher.
  [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ] && flags="${flags}CLAUDE_SANDBOX_ALLOW_FIREBASE=1 "
  # Jira: CLAUDE_SANDBOX_ALLOW_JIRA=1 makes the launcher read claude's own API
  # token from `pass` (entry claude/jira-token, not the JIRA_API_TOKEN entry your
  # `jira` alias reads) and export it as JIRA_API_TOKEN, with jira-cli pointed at
  # the session's own config, .jira/claude.yml (see CLAUDE_SANDBOX_ALLOW_JIRA in
  # claude-sandbox.bash, or claude-macos.bash on macOS). Only the flag is carried
  # here; the pass read happens in the launcher.
  [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = "1" ] && flags="${flags}CLAUDE_SANDBOX_ALLOW_JIRA=1 "
  # Extra hosts for a cf/cj session's network filter (see CLAUDE_SANDBOX_NET_ALLOW
  # in claude-sandbox.bash). Quoted: it holds spaces, and `*` must not glob.
  [ -n "${CLAUDE_SANDBOX_NET_ALLOW:-}" ] && flags="${flags}CLAUDE_SANDBOX_NET_ALLOW=$(printf '%q' "$CLAUDE_SANDBOX_NET_ALLOW") "
  # Some MCP plugins need a secret in claude's env, pulled from pass — the same
  # entries their interactive counterparts use — but only when that plugin is
  # selected, so ordinary launches don't fire a gpg prompt. Each $(…) stays
  # unevaluated here and runs at launch time (like the CONFIG_DIR var below);
  # bwrap inherits the result, so the MCP server spawned inside the sandbox sees
  # the value through the ${VAR:-} placeholder in its .mcp.json. Appended, not
  # assigned, so selecting more than one such plugin injects each one's secret.
  # A separate `case` per plugin keeps them independent (both can be selected).
  case "$__claude_plugins" in
    *figma-mcp*)
      # figma-developer-mcp reads FIGMA_API_KEY; same FIGMA_TOKEN entry the `figma`
      # REST wrapper uses. $(pass …) is intentionally literal — runs at launch.
      # shellcheck disable=SC2016
      secrets="${secrets}"'FIGMA_API_KEY=$(pass show "${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}" 2>/dev/null) '
      ;;
  esac
  case "$__claude_plugins" in
    *google-workspace-mcp*)
      # workspace-mcp reads GOOGLE_OAUTH_CLIENT_ID/SECRET; feed both from pass so no
      # long-lived client secret sits in the ambient env or a client_secret.json on
      # disk. $(pass …) is intentionally literal — runs at launch.
      # shellcheck disable=SC2016
      secrets="${secrets}"'GOOGLE_OAUTH_CLIENT_ID=$(pass show "${GOOGLE_OAUTH_CLIENT_ID_PASS:-GOOGLE_OAUTH_CLIENT_ID}" 2>/dev/null) '
      # shellcheck disable=SC2016
      secrets="${secrets}"'GOOGLE_OAUTH_CLIENT_SECRET=$(pass show "${GOOGLE_OAUTH_CLIENT_SECRET_PASS:-GOOGLE_OAUTH_CLIENT_SECRET}" 2>/dev/null) '
      ;;
  esac
  # __CLAUDE_CMD="CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance command claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-4-5-20251101 $args"
  __CLAUDE_CMD="${flags}${secrets}CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance ${prefix}claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-5-5 $__claude_args"
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
  __claude_provision_sandbox_overlay "$dir"
}

# Per-OS sandbox overlay, deep-merged (jq `*`) over the provisioned user
# settings so the shared settings.json stays platform-neutral. The two
# overlays point opposite ways:
# - settings.darwin.json turns Claude Code's built-in Seatbelt sandbox ON and
#   is the boundary there: bwrap is Linux-only, and Seatbelt can allow the
#   nix-daemon socket by path while Linux/seccomp cannot
#   (anthropics/claude-code#44180). It also carries what the macOS credential
#   opt-ins rely on (see claude-macos): Read deny rules that keep
#   the `firebase login` and gcloud credentials out of every session, and
#   `jira` run outside Seatbelt.
# - settings.linux.json turns the built-in sandbox OFF: recent claude-code
#   enables it by default when bubblewrap+socat are on PATH, but it cannot
#   start inside the claude-sandbox.bash jail (nested userns is blocked by
#   --disable-userns), so sandboxed Bash commands and !`…` slash-command
#   snippets fail or prompt for a per-command bypass. The jail already
#   isolates the whole process tree.
# User scope is load-bearing: the shared settings.json also rides --settings
# (CLI tier, above user), so a sandbox key there would leak across platforms
# — the Linux "off" would override Darwin's user-tier "on".
__claude_provision_sandbox_overlay() {
  local dir="$1" overlay
  case "$(uname -s)" in
    Darwin) overlay="$PERMEANCE_TREE/.claude/settings.darwin.json" ;;
    Linux) overlay="$PERMEANCE_TREE/.claude/settings.linux.json" ;;
    *) return 0 ;;
  esac
  [ -f "$overlay" ] && [ -f "$dir/settings.json" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "claude: jq not found; skipping sandbox settings overlay" >&2
    return 0
  fi
  local merged
  merged=$(jq -s '.[0] * .[1]' "$dir/settings.json" "$overlay") || {
    echo "claude: failed to merge sandbox settings overlay" >&2
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
  __claude_args=""
  [ "$#" -gt 0 ] && __claude_args=$(printf '%q ' "$@")

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  # Live tree (dev) → plugin .mcp.json edits apply without a rebuild; baked copy otherwise.
  [ -d "$PERMEANCE_TREE/.claude/plugins" ] && plugins_dir="$PERMEANCE_TREE/.claude/plugins"
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
  __claude_args=""
  [ "$#" -gt 0 ] && __claude_args=$(printf '%q ' "$@")

  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  # Live tree (dev) → plugin .mcp.json edits apply without a rebuild; baked copy otherwise.
  [ -d "$PERMEANCE_TREE/.claude/plugins" ] && plugins_dir="$PERMEANCE_TREE/.claude/plugins"
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

# Pick a past session of the current directory: Enter resumes it, ctrl-x erases
# it (after a y/N), the preview shows its conversation. The builtin picker (cr)
# can't delete one, and `claude project purge` wipes the whole project, its
# auto-memory included. claude-sessions (packages/claude/sessions) reads the
# transcripts; the instance is the first argument, as for __claude.
__claude_sessions() {
  local instance=1 id
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  if ! command -v claude-sessions >/dev/null; then
    echo "claude-sessions is not on PATH: rebuild, then open a new terminal" >&2
    return 1
  fi
  id=$(
    export CLAUDE_CONFIG_DIR="$HOME/.claude-$instance"
    claude-sessions list | eval fzf "$__CLAUDE_FZF" \
      "--delimiter='\t' --with-nth=2.. --accept-nth=1" \
      "--header='enter: resume · ctrl-x: erase'" \
      "--preview='claude-sessions preview {1}'" \
      "--preview-window='right,60%,border-none,wrap'" \
      "--bind='ctrl-x:execute(claude-sessions rm -ask {1})+reload(claude-sessions list)'"
  ) || return 0
  __claude "$instance" --resume "$id"
}
