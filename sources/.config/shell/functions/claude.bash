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
# A session __claude_vm starts takes the microVM launcher instead (see
# __claude_vm_prefix), and no escape hatch: that chord asked for the VM.
__claude_sandbox_prefix() {
  if [ "${__CLAUDE_LAUNCHER:-}" = claude-vm ]; then
    __claude_vm_prefix
    return
  fi
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
  # gh/jira/firebase sessions run behind claude-egress-proxy's network filter, and
  # the launcher refuses them without it: pre-checked here for the same reason.
  if { [ "${CLAUDE_SANDBOX_ALLOW_GH:-0}" = "1" ] || [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ] || [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = "1" ]; } &&
    ! command -v claude-egress-proxy >/dev/null 2>&1; then
    echo "claude: claude-egress-proxy not found on PATH; gh/jira/firebase sessions run behind its network filter, and the launcher refuses them without it. Rebuild the terminal to pick it up, or launch without the credential." >&2
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

# The microVM launcher, claude-vm (github:Runeword/claude-microvm): claude in a
# cloud-hypervisor guest with its own kernel, no network card, and the egress
# allowlist for every session, not only the credential ones. Fails closed like
# the sandbox gate, its checks run here in the calling shell for the same
# reason: no claude-vm, no launch. A gh, jira or firebase session goes through
# it too, its flag carried as for claude-sandbox: claude-vm reads the
# credential from pass and keeps it on the host, behind its egress proxy, and
# the VM holds a placeholder. Not figma-mcp, whose key this file puts in
# claude's environment for the VM to hold, nor google-workspace-mcp, whose
# token store it does not share: both are refused here, before a pane opens.
__claude_vm_prefix() {
  local script
  case "$__claude_plugins" in
    *figma-mcp* | *google-workspace-mcp*)
      echo "claude: the microVM does not carry figma-mcp or google-workspace-mcp yet; start them with cc. Refusing to launch." >&2
      return 1
      ;;
  esac
  if ! script=$(command -v claude-vm); then
    echo "claude: claude-vm not found on PATH; refusing to launch. Rebuild the terminal to pick it up." >&2
    return 1
  fi
  "$script" --check-cwd || return 1
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
  # GitHub: CLAUDE_SANDBOX_ALLOW_GH=1 makes the launcher read claude's own token
  # from `pass` (entry claude/gh-token, not the GH_TOKEN entry your `gh` alias
  # reads) and export it as GH_TOKEN, with your own `gh auth login` left masked
  # (see CLAUDE_SANDBOX_ALLOW_GH in claude-sandbox.bash; Linux only). Only the
  # flag is carried here; the pass read happens in the launcher.
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
  # Extra hosts for a gh/jira/firebase session's network filter (see
  # CLAUDE_SANDBOX_NET_ALLOW in claude-sandbox.bash). Quoted: it holds spaces,
  # and `*` must not glob.
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
      # Its OAuth token store, ~/.google_workspace_mcp, is masked in a session
      # that doesn't set this (see claude-sandbox.bash).
      flags="${flags}CLAUDE_SANDBOX_ALLOW_GOOGLE_WORKSPACE=1 "
      ;;
  esac
  # __CLAUDE_CMD="CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-$__claude_instance command claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-4-5-20251101 $args"
  __CLAUDE_CMD="${flags}${secrets}CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/$(__claude_profile) ${prefix}claude $__claude_plugins --allowedTools WebSearch,WebFetch --effort max --model claude-opus-5-5 $__claude_args"
}

# The profile a session runs with, under $HOME: .claude-N, or .claude-vm-N for
# one __claude_vm starts. claude-vm refuses a profile that holds a login, which
# the VM would read: its sessions sign in through the host's relay instead, so
# they keep a profile of their own, with no .credentials.json in it.
__claude_profile() {
  if [ "${__CLAUDE_LAUNCHER:-}" = claude-vm ]; then
    printf '.claude-vm-%s' "$__claude_instance"
  else
    printf '.claude-%s' "$__claude_instance"
  fi
}

# Make sources/ own each profile's user-level config: path-scoped rules and bundled
# settings load via the `user` setting source (which the claude wrapper must enable),
# while per-profile state (auth, sessions) stays separate. rules/ is a symlink;
# settings.json is a refreshed copy so Claude's writes can't pollute sources/ or a read-only store.
# The config is the live tree's .claude (dev); in bundled mode $PERMEANCE_TREE is
# zsh's own bundle, which has none, so it is the claude wrapper's, as for the plugins
# in __claude_init. Fails when neither exists, like the overlay below: a profile left
# unprovisioned would launch without its sandbox settings.
__claude_provision_config() {
  local src="$PERMEANCE_TREE/.claude"
  [ -d "$src" ] || src="$NIX_OUT_SHELL/paths/claude/.claude"
  if [ ! -d "$src" ]; then
    echo "claude: neither PERMEANCE_TREE nor the bundled claude has a .claude config; refusing to launch without its settings" >&2
    return 1
  fi
  local dir name planted
  dir="$HOME/$(__claude_profile)"
  mkdir -p "$dir"
  # The profile's user-level instructions load into every session, in every
  # project: CLAUDE.md, rules/, agents/, commands/ and skills/. A session can
  # write its profile, so what one leaves there would steer every later one, a
  # credential or unsandboxed session included. sources/.claude owns them: each
  # is a symlink to its copy there, and one that sources/.claude lacks is
  # removed. `ln -sfn` onto a *real directory* does not replace it — it creates
  # the link inside it (rules/rules -> …) and exits 0 — so a real one is removed
  # first.
  for name in rules agents commands CLAUDE.md; do
    if [ -e "$src/$name" ]; then
      if [ -e "$dir/$name" ] && [ ! -L "$dir/$name" ]; then
        rm -rf "${dir:?}/${name:?}"
      fi
      ln -sfn "$src/$name" "$dir/$name"
    elif [ -e "$dir/$name" ] || [ -L "$dir/$name" ]; then
      rm -rf "${dir:?}/${name:?}"
      echo "claude: removed $dir/$name: sources/.claude has none, and a session can plant one for every later session" >&2
    fi
  done
  # skills/ cannot be a link into sources/: claude downloads the claude.ai
  # account's skills into skills/synced at every start. That download is also
  # why removing all of skills/ is safe; only what else was there is reported.
  if [ -e "$dir/skills" ] || [ -L "$dir/skills" ]; then
    planted=$(find "$dir/skills" -mindepth 1 -maxdepth 1 ! -name synced 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')
    planted=${planted% }
    [ -L "$dir/skills" ] && planted="a link to $(readlink "$dir/skills")"
    rm -rf "${dir:?}/skills"
    if [ -n "$planted" ]; then
      echo "claude: removed $planted from $dir/skills: a session can plant skills there for every later session" >&2
    fi
  fi
  [ -f "$src/settings.json" ] && install -m644 "$src/settings.json" "$dir/settings.json"
  __claude_provision_sandbox_overlay "$src" "$dir"
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
# Fails closed, like the sandbox gate: on macOS the overlay is the sandbox, so a
# merge that fails (no jq, no overlay, bad JSON) refuses the launch.
__claude_provision_sandbox_overlay() {
  local src="$1" dir="$2" overlay merged
  case "$(uname -s)" in
    Darwin) overlay="$src/settings.darwin.json" ;;
    Linux) overlay="$src/settings.linux.json" ;;
    *) return 0 ;;
  esac
  if ! merged=$(jq -s '.[0] * .[1]' "$dir/settings.json" "$overlay"); then
    echo "claude: could not merge $overlay into $dir/settings.json; refusing to launch without the sandbox settings" >&2
    return 1
  fi
  printf '%s\n' "$merged" >"$dir/settings.json"
}

# A session can write its profile and the directory it runs in, and the next
# session loads what it left there without asking: MCP servers in the profile's
# .claude.json (user and local scope) start with no approval prompt, and
# .claude/settings.local.json can carry hooks, apiKeyHelper, env or plugins. The
# next session may hold a credential the first never had (cc), run unsandboxed,
# or run on macOS, where hooks and MCP servers are outside Seatbelt. So each
# launch empties those server lists and cuts the local settings to what claude
# writes there itself: its "don't ask again" permission rules and the Show tips
# toggle. MCP servers belong in a plugin under sources/.claude/plugins and
# project hooks in .claude/settings.json, both pinned in the sandbox. A file jq
# can't read refuses the launch.
__claude_scrub_planted() {
  local f names
  f="$HOME/$(__claude_profile)/.claude.json"
  if [ -e "$f" ]; then
    names=$(jq -r '[.mcpServers // {}, (.projects // {} | .[].mcpServers // {})] | map(keys[]) | unique | join(", ")' "$f") || {
      echo "claude: could not read $f; refusing to launch with the MCP servers it may name" >&2
      return 1
    }
    if [ -n "$names" ]; then
      __claude_rewrite_json "$f" 'if .mcpServers then .mcpServers = {} else . end | if .projects then .projects[] |= (if .mcpServers then .mcpServers = {} else . end) else . end' || return 1
      echo "claude: removed the MCP servers $names from $f: they would start without approval" >&2
    fi
  fi
  f="$PWD/.claude/settings.local.json"
  if [ -e "$f" ]; then
    names=$(jq -r '[(keys_unsorted[] | select(. != "permissions" and . != "spinnerTipsEnabled")), (.permissions // {} | keys_unsorted[] | select(. != "allow" and . != "deny" and . != "ask") | "permissions." + .)] | join(", ")' "$f") || {
      echo "claude: could not read $f; refusing to launch with the settings it may hold" >&2
      return 1
    }
    if [ -n "$names" ]; then
      __claude_rewrite_json "$f" 'with_entries(select(.key == "permissions" or .key == "spinnerTipsEnabled")) | if .permissions then .permissions |= with_entries(select(.key == "allow" or .key == "deny" or .key == "ask")) else . end' || return 1
      echo "claude: dropped $names from $f: claude writes only its permission rules there" >&2
    fi
  fi
}

# Rewrite the JSON file $1 through the jq filter $2, atomically.
__claude_rewrite_json() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  if jq "$2" "$1" >"$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  echo "claude: could not rewrite $1; refusing to launch" >&2
  return 1
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

  __claude_provision_config || return 1
  __claude_build_cmd || return 1
  __claude_scrub_planted
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

  __claude_provision_config || return 1
  __claude_build_cmd || return 1
  __claude_scrub_planted
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

# __claude in the microVM (leader cv): the same session, profile and plugins,
# started through claude-vm instead of claude-sandbox. A local, which
# __claude_sandbox_prefix sees the way __claude sees __claude_connect's picks,
# so the next plain launch gets claude-sandbox again.
__claude_vm() {
  local __CLAUDE_LAUNCHER=claude-vm
  __claude "$@"
}

__claude_plugins() {
  __claude_init_fzf "$@" || return 0
  __claude_run
}

# Pick the session's connections with fzf, then launch a normal session (default
# plugins included) with them added: one leader chord (cc) instead of one per
# credential and per combination. A connection is a credential the sandbox
# launcher hands a single session (firebase, jira, gh: the CLAUDE_SANDBOX_ALLOW_*
# flags in __claude_build_cmd) or an MCP plugin (a plugin with a .mcp.json).
# Picked with gh, firebase or jira, an MCP plugin sits behind their network
# filter too, so the hosts it calls go in CLAUDE_SANDBOX_NET_ALLOW. Takes what
# __claude takes: the instance, then claude's arguments.
__claude_connect() {
  local plugins_dir="$NIX_OUT_SHELL/paths/claude/.claude/plugins"
  # Live tree (dev) → plugin .mcp.json edits apply without a rebuild; baked copy otherwise.
  [ -d "$PERMEANCE_TREE/.claude/plugins" ] && plugins_dir="$PERMEANCE_TREE/.claude/plugins"
  local selected c
  selected=$(
    {
      printf '%s\n' firebase jira gh
      find -L "$plugins_dir" -mindepth 2 -maxdepth 2 -name .mcp.json 2>/dev/null |
        sed 's|/\.mcp\.json$||; s|.*/||' | sort
    } | eval fzf --multi "$__CLAUDE_FZF"
  ) || return 0
  # Locals: __claude reads them (a function sees its caller's locals), and the
  # shell drops them on return, so the next plain launch gets none of them. The
  # session gets exactly what was picked: a credential sets the launcher's
  # opt-in flag, an MCP plugin joins the default plugins.
  local CLAUDE_SANDBOX_ALLOW_FIREBASE=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_GH=0
  local -a __CLAUDE_DEFAULT_PLUGINS=("${__CLAUDE_DEFAULT_PLUGINS[@]}")
  while IFS= read -r c; do
    case "$c" in
      firebase) CLAUDE_SANDBOX_ALLOW_FIREBASE=1 ;;
      jira) CLAUDE_SANDBOX_ALLOW_JIRA=1 ;;
      gh) CLAUDE_SANDBOX_ALLOW_GH=1 ;;
      ?*) __CLAUDE_DEFAULT_PLUGINS+=("$c") ;;
    esac
  done <<<"$selected"
  __claude "$@"
}

# The connection picker in the microVM (leader cvc): what __claude_connect
# picks, launched through claude-vm, as __claude_vm launches a plain session.
__claude_vm_connect() {
  local __CLAUDE_LAUNCHER=claude-vm
  __claude_connect "$@"
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

# claude-sessions (packages/claude/sessions) reads the transcripts for the
# session pickers and backs the open sessions up; the terminal ships it.
__claude_sessions_on_path() {
  command -v claude-sessions >/dev/null && return 0
  echo "claude-sessions is not on PATH: rebuild, then open a new terminal" >&2
  return 1
}

# fzf over the past sessions of the current directory, each previewed as its
# conversation, for the three pickers below: the instance, then fzf options for
# eval.
__claude_sessions_fzf() {
  __claude_sessions_on_path || return 1
  (
    export CLAUDE_CONFIG_DIR="$HOME/.claude-$1"
    shift
    claude-sessions list | eval fzf "$__CLAUDE_FZF" \
      "--delimiter='\t' --with-nth=2.." \
      "--preview='claude-sessions preview {1}'" \
      "--preview-window='right,60%,border-none,wrap'" "$*"
  )
}

# Pick a past session of the current directory and resume it. The instance is
# the first argument, as for __claude.
__claude_sessions() {
  local instance=1 id
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  id=$(__claude_sessions_fzf "$instance" --accept-nth=1 "--header='enter: resume'") || return 0
  __claude "$instance" --resume "$id"
}

# Pick a past session of the current directory and fork it: claude resumes a
# copy of its conversation under a new session ID, and the original stays as it
# was, for cs to resume later. The instance is the first argument, as for
# __claude.
__claude_sessions_fork() {
  local instance=1 id
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  id=$(__claude_sessions_fzf "$instance" --accept-nth=1 "--header='enter: fork'") || return 0
  __claude "$instance" --resume "$id" --fork-session
}

# Pick past sessions of the current directory and erase them, after one y/N:
# tab marks several, enter erases the marked ones (else the one under the
# cursor). The builtin picker (cr) can't delete a session, and `claude project
# purge` wipes the whole project, its auto-memory included. fzf becomes
# `claude-sessions rm`, which reads the y/N from the terminal and leaves what
# it erased on screen. The instance is the first argument, as for __claude.
__claude_sessions_rm() {
  local instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  __claude_sessions_fzf "$instance" --multi "--header='tab: mark · enter: erase'" \
    "--bind='enter:become(claude-sessions rm -ask {+1})'" || return 0
}

# Save the sessions open on this machine, in every profile, for
# __claude_sessions_restore to start again later: after a reboot, or once a
# claude update is in. claude-sessions finds them in Claude Code's own registry
# on macOS, and through /proc on Linux, where the registry loses every
# sandboxed session but one; it keeps its 20 newest backups in
# $XDG_STATE_HOME/claude-sessions, read-only in the sandbox.
__claude_sessions_backup() {
  __claude_sessions_on_path || return 0
  claude-sessions backup
}

# Start the sessions of the last backup again, each in a tmux window of its
# own: fzf lists them all marked, tab unmarks one, enter resumes the marked
# ones. claude-sessions saved leaves out, saying why, a session still open and
# one whose conversation or directory is gone.
__claude_sessions_restore() {
  __claude_sessions_on_path || return 0
  if [ -z "$TMUX" ]; then
    echo "claude: restoring opens a tmux window for each session; run it in tmux" >&2
    return 0
  fi
  local rows id instance dir conns net plugins tsession title _
  rows=$(claude-sessions saved) || return 0
  [ -n "$rows" ] || return 0
  rows=$(printf '%s\n' "$rows" | eval fzf "$__CLAUDE_FZF" --multi \
    "--delimiter='\t' --with-nth=9 --bind=load:select-all" \
    "--preview='CLAUDE_CONFIG_DIR=\$HOME/.claude-{2} claude-sessions preview {1}'" \
    "--preview-window='right,60%,border-none,wrap'" \
    "--header='tab: unmark · enter: resume'") || return 0
  # A row: the session's id, profile, directory, connections, extra hosts of
  # its network filter, plugins and tmux session ("-" for none), then its
  # title and what fzf showed.
  while IFS=$'\t' read -r id instance dir conns net plugins tsession title _; do
    __claude_sessions_reopen "$id" "$instance" "$dir" "$conns" "$net" "$plugins" "$tsession" &&
      printf 'claude: resumed %s in %s\n' "$title" "$dir"
  done <<<"$rows"
}

# Resume session $1 of profile $2 as __claude started it: from its directory
# $3, with the connections $4 and plugins $6 it had (comma-separated, set as
# __claude_connect sets its picks) and the extra hosts $5 of its network
# filter, in a new window of tmux session $7 while that is still there; "-"
# stands for none. A subshell keeps the directory and variables to it.
__claude_sessions_reopen() {
  (
    cd -- "$3" || exit 1
    CLAUDE_SANDBOX_ALLOW_GH=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_FIREBASE=0
    case ",$4," in *,gh,*) CLAUDE_SANDBOX_ALLOW_GH=1 ;; esac
    case ",$4," in *,jira,*) CLAUDE_SANDBOX_ALLOW_JIRA=1 ;; esac
    case ",$4," in *,firebase,*) CLAUDE_SANDBOX_ALLOW_FIREBASE=1 ;; esac
    CLAUDE_SANDBOX_NET_ALLOW=$5
    [ "$5" = - ] && CLAUDE_SANDBOX_NET_ALLOW=
    __CLAUDE_DEFAULT_PLUGINS=()
    local rest=$6
    [ "$rest" = - ] && rest=
    while [ -n "$rest" ]; do
      __CLAUDE_DEFAULT_PLUGINS+=("${rest%%,*}")
      case "$rest" in
        *,*) rest=${rest#*,} ;;
        *) rest= ;;
      esac
    done
    __claude_init "$2" --resume "$1" || exit 1
    if [ "$7" != - ] && tmux has-session -t "=$7" 2>/dev/null; then
      tmux new-window -d -t "=$7:" -c "$3" "$__CLAUDE_CMD"
    else
      tmux new-window -d -c "$3" "$__CLAUDE_CMD"
    fi
  )
}
