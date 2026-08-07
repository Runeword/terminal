#!/usr/bin/env bash
# Run a command (normally `claude`) inside an unprivileged bubblewrap namespace.
#
# Why not Claude Code's own `/sandbox`: its Linux implementation applies a seccomp
# filter that unconditionally blocks socket(AF_UNIX, …), which severs the
# nix-daemon socket and breaks every `nix` invocation. See
# anthropics/claude-code#44180. This wrapper reproduces the useful half —
# filesystem isolation — without the seccomp layer, and covers the *whole*
# process: Claude's file tools, its hooks, and every MCP server, none of which
# the built-in sandbox ever isolated (it only wrapped Bash).
#
# Boundary:
#   - entire filesystem read-only; own pid/ipc/uts namespaces; no nested userns
#   - writable: cwd (launch refused when that would cover $HOME),
#     $CLAUDE_CONFIG_DIR, nix/direnv caches, the google-workspace-mcp token
#     store, /tmp — all created up front so a first run can't hit EROFS
#   - the host-executed files inside those writable regions are re-pinned
#     read-only on top of them (bwrap applies binds in order, so a later
#     --ro-bind wins): $PERMEANCE_TREE's direnvrc/zshrc, $PWD/.direnv/bin,
#     direnv's source_url CAS, $PWD/.git/{hooks,config} and lefthook*.yml.
#     Writing one line into any of them is host code execution on the user's
#     next cd or commit, which would undo every mask below. This is a named
#     list, not a guarantee about the whole cwd: flake.nix and devshells/ stay
#     writable because editing them is the point of the repo, so a poisoned
#     shellHook re-evaluated by direnv remains a residual hole here.
#     CLAUDE_SANDBOX_UNLOCK_SOURCES=1 lifts exactly one of these locks — the
#     $PERMEANCE_TREE one, for sessions deliberately editing shell config. The
#     rest ($PWD/.direnv, direnv's CAS, $PWD/.git/{hooks,config},
#     lefthook*.yml) are never what such a session set out to edit, so they
#     hold unconditionally: one flag that dropped all five turned "edit a zsh
#     alias" into "hand over the git hook path for the session".
#     When the flag is set the tree is bound read-write explicitly rather than
#     merely left unlocked, so it works from any cwd — the lock-only form was a
#     silent no-op whenever $PERMEANCE_TREE lay outside the writable cwd, i.e.
#     every launch from a project other than the one holding the tree.
#   - a seccomp filter fails ioctl(TIOCSTI/TIOCLINUX) with EPERM. Without it the
#     namespace can push characters into the launching terminal's input queue
#     (CVE-2017-5226) and the host shell runs them once claude exits — bwrap's
#     manual calls for --new-session or seccomp here, and --new-session costs
#     the TUI its controlling terminal (SIGWINCH). This filter touches nothing
#     else, so it does not reintroduce the AF_UNIX block that made Claude
#     Code's own sandbox unusable with nix.
#   - the read-only remount does not stop connect(2): socket inodes stay usable
#     through --ro-bind, which is exactly what keeps the nix-daemon socket
#     alive — and would equally expose every other host socket. So the control
#     planes are masked: $XDG_RUNTIME_DIR (session D-Bus, systemd --user API,
#     keyring, gpg-agent) becomes a private tmpfs, and the system D-Bus,
#     docker/podman/libvirt, and tmux/X11 sockets are masked individually. The
#     ssh agent socket is re-bound as the one deliberate channel: signing
#     happens outside the namespace, keys cannot be read through it.
#   - credential stores masked at their conventional and XDG-relocated paths —
#     shell/xdg.sh moves gnupg, aws, docker, kube and npm under ~/.config, so a
#     mask list naming only the legacy dotdirs would mask nothing. ~/.config/gh
#     is masked too: an `ask` rule on Bash(gh *) is not a control here, because
#     the Read tool and every hook/MCP server reach the file without going
#     through Bash at all. Set CLAUDE_SANDBOX_ALLOW_GH=1 when a session needs
#     the gh CLI.
#   - ~/.ssh replaced by a sanitized copy: config plus its Includes,
#     known_hosts, and one public key per IdentityFile, so `IdentitiesOnly yes`
#     is satisfied and git-over-ssh keeps working while private keys never
#     enter the namespace — deliberately no fallback that exposes the real
#     ~/.ssh, even when the agent holds no identity
#
# Deliberately NOT isolated:
#   - the network. bwrap alone offers no domain filtering, so this is a
#     containment boundary against filesystem damage and credential reads, not
#     against exfiltration.
#   - the nix-daemon socket, which is the whole reason this wrapper exists. Note
#     what that costs: a client the daemon considers trusted may override daemon
#     settings (post-build-hook, pre-build-hook, diff-hook, build-users-group),
#     each of which makes the *root* daemon run a caller-chosen program. So on a
#     host where the launching user is in nix.conf's trusted-users, this socket
#     is a root-equivalent hole straight through the boundary, and no mask below
#     can close it. The check near the end of this script warns when that is the
#     case; the actual fix is dropping the user from trusted-users in the system
#     configuration, which is outside this repo.

set -euo pipefail
umask 077

if ! command -v bwrap >/dev/null 2>&1; then
  echo "claude-sandbox: bwrap not found on PATH" >&2
  exit 1
fi

[ "$#" -gt 0 ] || {
  echo "usage: claude-sandbox.bash <command> [args…]" >&2
  exit 64
}

# Binding the cwd read-write from $HOME or an ancestor would hand the namespace
# the whole home directory minus the masks below — a silent no-op sandbox.
#
# Compared on *physical* paths. $PWD is bash's logical cwd, which keeps whatever
# symlinks were traversed to reach it, so a prefix test against it is defeated by
# any symlink pointing into $HOME: with `ln -s /home /h`, `cd /h/charles` passes
# this check and binds the whole home directory read-write. bwrap resolves a bind
# source regardless, so re-resolving here is also what makes the test describe
# the mount that actually gets created.
cd -P . || {
  echo "claude-sandbox: cannot resolve the current directory" >&2
  exit 64
}
# $HOME and its ancestors give the no-op sandbox above. The XDG config/data trees
# are refused for a second reason: they hold code the desktop session executes
# without being asked — ~/.config/systemd/user, ~/.config/autostart, ~/.local/bin
# — so read-write access to them is host code execution at the next login, which
# none of the masks below can undo.
for __cs_bad in \
  "$HOME" \
  "${XDG_CONFIG_HOME:-$HOME/.config}" \
  "${XDG_DATA_HOME:-$HOME/.local/share}" \
  "$HOME/.local"; do
  __cs_bad=$(readlink -m "$__cs_bad")
  case "$__cs_bad/" in
    "${PWD%/}/"*)
      echo "claude-sandbox: refusing to bind $PWD read-write — it contains $__cs_bad; run from a project directory (or CLAUDE_SANDBOX=0 to launch unsandboxed)" >&2
      exit 64
      ;;
  esac
done
# The trees the desktop session executes from without being asked. These are
# refused in *both* directions, unlike the roots above: a cwd inside
# ~/.config/systemd/user is host code execution at the next login just as surely
# as one that contains it. Kept to the executing subtrees rather than all of
# ~/.config so that the ordinary case of a config repo at ~/.config/nvim still
# works.
for __cs_bad in \
  "${XDG_CONFIG_HOME:-$HOME/.config}/systemd" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/autostart" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/systemd" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/applications" \
  "$HOME/.local/bin"; do
  __cs_bad=$(readlink -m "$__cs_bad")
  case "${PWD%/}/" in
    "$__cs_bad/"*)
      echo "claude-sandbox: refusing to bind $PWD read-write — it is inside $__cs_bad, which your desktop session executes at login (or CLAUDE_SANDBOX=0 to launch unsandboxed)" >&2
      exit 64
      ;;
  esac
done

# Runs exactly the gate above — same list, same message — and stops. __claude_run
# starts claude through `tmux new-window`, whose pane clears the moment the
# command dies, so a refusal has to be printed by the *calling* shell to be read
# at all. Exposing the gate keeps claude.bash from carrying a second copy of this
# list that drifts away from this one.
if [ "${1:-}" = "--check-cwd" ]; then
  exit 0
fi

# Workspace for the sanitized copies and mask sources. Deliberately NOT under
# /tmp: /tmp is bind-mounted read-write into the namespace, so a workspace
# there could be rewritten by the sandboxed process through its real path,
# bypassing every read-only bind built from it. $XDG_RUNTIME_DIR is masked by
# a private tmpfs inside the namespace, and ~/.cache stays read-only inside,
# so either parent keeps the workspace unreachable-or-immutable.
# The per-user runtime dir, replaced by a private tmpfs further down — the single
# highest-value mask in this file (Wayland and the Alacritty IPC socket, the
# systemd --user bus, gpg-agent, pipewire). XDG_RUNTIME_DIR is not in tmux's
# update-environment, so a pane taken from a server started before the variable
# existed inherits nothing and the mask would be skipped in silence. Fall back to
# the canonical path rather than lose it, and say so if even that is absent.
__cs_xdg="${XDG_RUNTIME_DIR:-}"
if [ -z "$__cs_xdg" ] || [ ! -d "$__cs_xdg" ]; then
  __cs_xdg="/run/user/$(id -u)"
fi
if [ ! -d "$__cs_xdg" ]; then
  __cs_xdg=""
  echo "claude-sandbox: WARNING — no per-user runtime directory found; the session bus, keyring, and compositor sockets are NOT masked" >&2
fi

__cs_ws_parent="$__cs_xdg"
[ -n "$__cs_ws_parent" ] || __cs_ws_parent="$HOME/.cache"
mkdir -p "$__cs_ws_parent"
__cs_tmp=$(mktemp -d "$__cs_ws_parent/claude-sandbox.XXXXXXXX")
trap 'rm -rf "$__cs_tmp"' EXIT

args=(
  --ro-bind / /
  --dev /dev
  --proc /proc
  --unshare-user
  --unshare-pid
  --unshare-ipc
  --unshare-uts
  --unshare-cgroup-try
  --disable-userns
  --die-with-parent
  --chdir "$PWD"
)

# Writable regions. The ones under $HOME are created first: the rest of the
# filesystem is read-only inside, so a region missing at setup could never be
# created from within and every write would hit EROFS — a first-run failure in
# exactly the nix flows this wrapper exists to keep working.
__cs_writable=(
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  "$HOME/.cache/nix"
  # Deliberately the children, not $HOME/.local/state/nix itself: that directory
  # holds `profile`, a symlink whose /bin is on the *host* PATH ahead of
  # /run/current-system/sw/bin (NixOS puts it there twice via /etc/set-environment).
  # A writable parent lets the symlink be unlinked and replaced by a real
  # directory, shadowing nix/ssh/systemctl for the interactive shell. Keeping the
  # parent read-only pins the symlink while leaving what nix writes writable.
  "$HOME/.local/state/nix/profiles"
  "$HOME/.local/state/nix/defexpr"
  "$HOME/.cache/direnv"
  # Go's build cache and golangci-lint's fact cache. This repo builds Go binaries
  # (packages/custom/*), and lefthook's pre-commit runs gofumpt and golangci-lint
  # over them, so read-only here does not merely slow things down — golangci-lint
  # reports "0 issues" after its typechecking fails on the read-only cache, which
  # is a false pass on a commit hook. Left as ordinary writable rather than a
  # tmpfs like ~/.cache/nix: Go's cache is content-addressed and verifies an
  # entry's hash on read, so it lacks the poison-by-path property that makes nix's
  # eval and fetcher caches a host code-execution path.
  "${GOCACHE:-$HOME/.cache/go-build}"
  "${GOLANGCI_LINT_CACHE:-$HOME/.cache/golangci-lint}"
  # OAuth token store for google-workspace-mcp (shipped by wrappers/claude.nix);
  # read-only would break token refresh.
  "$HOME/.google_workspace_mcp"
)
mkdir -p "${__cs_writable[@]}"
for p in "$PWD" "${__cs_writable[@]}" /tmp; do
  [ -d "$p" ] && args+=(--bind "$p" "$p")
done

# Mask sources: a user-owned empty dir/file. /dev/null can't serve as the file
# mask — inside the user namespace root maps to the overflow uid, and OpenSSH
# rejects config files whose owner looks wrong.
mkdir -p "$__cs_tmp/empty"
: >"$__cs_tmp/null"
__cs_mask() {
  if [ -d "$1" ]; then
    args+=(--ro-bind "$__cs_tmp/empty" "$1")
  elif [ -e "$1" ]; then
    args+=(--ro-bind "$__cs_tmp/null" "$1")
  fi
}
# Re-pin a path read-only on top of a writable region (later bind wins).
#
# The trailing `return 0` is load-bearing. Every call below is a bare statement
# under `set -e`, and a function whose body ends in a false test returns that
# status — even though the identical `a && b` written inline would not exit,
# because there the failing command is not the last of the AND-list. With the
# test trailing, an absent target aborted the entire launch before bwrap and
# before any message could be printed. That is the common case, not the rare
# one: .direnv, .git/hooks and lefthook*.yml are all absent in most repositories,
# and the pane simply died with `Pane is dead (status 1)`.
#
# An absent target is recorded, not silently skipped: each one sits inside a
# writable region, so what the sandbox cannot poison it can instead *create*. The
# two the host tool would create anyway are pre-created just below; the rest are
# named on stderr, because bwrap cannot pre-create a mountpoint for us — it would
# materialise on the host through the read-write bind and outlive the sandbox.
__cs_unlocked=()
__cs_relock() {
  if [ -z "${1:-}" ]; then
    return 0
  elif [ -e "$1" ]; then
    args+=(--ro-bind "$1" "$1")
  else
    __cs_unlocked+=("$1")
  fi
  return 0
}

# Everything the *host* shell sources or executes, re-pinned read-only over the
# writable regions above. Each of these is host code execution, not merely a
# weaker next sandbox:
#   - $PERMEANCE_TREE: .zshrc/.bashrc source every functions/*.sh from it, the
#     tmux config run-shells ~50 paths in it, DIRENV_CONFIG points at its
#     direnvrc (which direnv's allow-hash does not cover — that hash is for
#     .envrc only), and claude.bash executes the launcher from it, so a write
#     here also rewrites this boundary for the next launch. Also read by the
#     git-shim on every git call, which re-reads git-allowlist.toml each time.
#   - $PWD/.direnv: nix-direnv puts bin/ on the host PATH and the host shell
#     evals flake-profile-*.rc on each direnv load.
#   - direnv's source_url CAS: cmd_fetchurl returns a cache hit by path without
#     re-hashing it, so the pinned sha256 in direnvrc protects only the first
#     fetch. Poisoning the entry runs in the host shell on the next cd — and
#     unlike the two above, that works from any project directory, not just this
#     repo's, so it is not covered by the cwd lock.
#
# Give the locks something to pin in the places where an absent target is a hole
# rather than a non-issue, and where the host tool would create the same thing
# moments later anyway: direnv's CAS (a cache directory direnv owns), $PWD/.direnv
# but only where an .envrc makes direnv live for this repo — so no stray directory
# appears in projects that do not use it — and $PWD/.git/hooks, which git creates
# at init and which is absent only in a repo someone has pruned.
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/direnv/cas"
if [ -e "$PWD/.envrc" ]; then
  mkdir -p "$PWD/.direnv"
fi
if [ -d "$PWD/.git" ]; then
  mkdir -p "$PWD/.git/hooks"
fi
# Unconditional locks. CLAUDE_SANDBOX_UNLOCK_SOURCES does not reach these: a
# session that sets it is editing shell config, never .git/hooks or lefthook.yml,
# so lifting them together only widened the boundary for no gain — "edit a zsh
# alias" also meant "the git hook path is writable until this session ends".
#
# Each lock is attempted only where the tool it protects is actually in play,
# so a target recorded as absent below is a real anomaly rather than "this repo
# does not use direnv" — otherwise the warning fires on every ordinary project
# and is trained away within a day.
if [ -e "$PWD/.envrc" ]; then
  __cs_relock "$PWD/.direnv"
fi
# Host-executed files inside the writable cwd. git runs .git/hooks/* and honours
# .git/config (core.hooksPath, `!`-aliases, clean/smudge filters) on the *host*
# at the user's next git command; lefthook reads lefthook*.yml there too. None
# of these are git subcommands, so the git-shim allowlist never sees the write —
# a one-line append is unsandboxed host code execution. Relocking only .git/hooks
# would be bypassable via core.hooksPath, so .git/config is relocked too (cost:
# `git config`/`git remote` writes inside the sandbox are refused outright now
# that no flag lifts this; reads, commits, staging, and checkout are unaffected).
# flake.nix/flake.lock/devshells stay writable by necessity — editing this flake
# is the repo's purpose — so a poisoned shellHook re-evaluated by direnv on the
# next cd is a residual risk this lock does not cover (.envrc is self-guarding
# via direnv's allow-hash; flake.nix is not).
if [ -d "$PWD/.git" ]; then
  __cs_relock "$PWD/.git/hooks"
  __cs_relock "$PWD/.git/config"
fi
# Locked where lefthook is configured. Where it is not, a lefthook.yml the
# sandbox creates sits inert: .git/hooks is already read-only above, so nothing
# invokes lefthook unless the user runs it by hand in a repo that, until this
# session, had no lefthook config — which `git status` shows as an untracked
# file first.
for __cs_lh in "$PWD/lefthook.yml" "$PWD/lefthook-generated.yml"; do
  if [ -e "$__cs_lh" ]; then
    __cs_relock "$__cs_lh"
  fi
done
__cs_relock "${XDG_CACHE_HOME:-$HOME/.cache}/direnv/cas"

# The single lock CLAUDE_SANDBOX_UNLOCK_SOURCES lifts, applied last so the
# read-write bind wins over anything above it that happens to contain the tree.
#
# Bound read-write explicitly rather than just left unlocked. Omitting the lock
# only helps where the tree already sits inside the writable cwd, so `cu` from
# any other project was a silent no-op — the tree stayed read-only through the
# root bind and the warning below claimed otherwise. An explicit bind makes the
# flag mean the same thing from every directory.
if [ "${CLAUDE_SANDBOX_UNLOCK_SOURCES:-0}" = "1" ]; then
  case "${PERMEANCE_TREE:-}" in
    "")
      echo "claude-sandbox: CLAUDE_SANDBOX_UNLOCK_SOURCES=1 has nothing to unlock — PERMEANCE_TREE is unset" >&2
      ;;
    # Bundled mode resolves PERMEANCE_TREE to the wrapper's own store path, which
    # is root-owned and read-only however it is bound. Say so instead of emitting
    # a bind that cannot work: the tree the user means to edit is their working
    # copy, reachable only by launching with PERMEANCE_ROOT set to it.
    /nix/store/*)
      echo "claude-sandbox: CLAUDE_SANDBOX_UNLOCK_SOURCES=1 has nothing to unlock — PERMEANCE_TREE is a store path ($PERMEANCE_TREE); relaunch the terminal with PERMEANCE_ROOT pointing at your working tree" >&2
      ;;
    *)
      if [ -d "$PERMEANCE_TREE" ]; then
        args+=(--bind "$PERMEANCE_TREE" "$PERMEANCE_TREE")
        echo "claude-sandbox: CLAUDE_SANDBOX_UNLOCK_SOURCES=1 — $PERMEANCE_TREE is writable; edits to it run on your host, outside this sandbox" >&2
      else
        echo "claude-sandbox: CLAUDE_SANDBOX_UNLOCK_SOURCES=1 has nothing to unlock — PERMEANCE_TREE '$PERMEANCE_TREE' is not a directory" >&2
      fi
      ;;
  esac
else
  if [ -z "${PERMEANCE_TREE:-}" ]; then
    echo "claude-sandbox: WARNING — PERMEANCE_TREE is unset, so the shell config tree cannot be locked; anything written to it runs on your host" >&2
  fi
  __cs_relock "${PERMEANCE_TREE:-}"
fi
if [ "${#__cs_unlocked[@]}" -gt 0 ]; then
  echo "claude-sandbox: absent, so not locked: ${__cs_unlocked[*]} — nothing stops the sandbox creating them, and your host runs what it finds there" >&2
fi

# nix's caches, made private rather than shared. They are keyed by path and
# returned without re-verification — eval-cache-v6/*.sqlite for evaluation
# results, fetcher-cache-v4.sqlite for fetched sources — so a poisoned entry
# makes the *host*'s next nix command resolve an input to an attacker-chosen
# store path. That is the same argument the direnv CAS lock rests on, applied
# consistently. A tmpfs rather than a read-only bind because nix genuinely needs
# to write here (the writable list exists so first-run nix flows don't hit
# EROFS); the cost is a cold cache per session, not a broken one.
args+=(--tmpfs "$HOME/.cache/nix")

# The read-only remount never blocks connect(2), so every host unix socket is
# an escape hatch by default — /var/run/docker.sock alone is root-equivalent,
# and the tmux socket would let the namespace type into host panes. Replace the
# per-user runtime tree with a private tmpfs and mask the rest individually.
# Extend this list when a new daemon socket appears on the host.
if [ -n "$__cs_xdg" ]; then
  args+=(--perms 0700 --tmpfs "$__cs_xdg")
fi
# tmux's socket directory, created the way tmux itself creates it (0700, ours)
# when absent. /tmp is writable inside the namespace, so an absent mask target
# here is not a harmless no-op: the sandbox could create the directory and a
# socket in it, and the user's next `tmux` would attach to a server it controls.
# Not `mkdir -p -m`: with -p the mode applies only to the deepest component, so
# a nested TMUX_TMPDIR would get default perms on the intermediates. Creating
# just the leaf, and only when absent, is what tmux itself does.
__cs_tmux_dir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
if [ ! -e "$__cs_tmux_dir" ]; then
  mkdir -m 0700 "$__cs_tmux_dir" 2>/dev/null || true
fi
for p in \
  /run/dbus/system_bus_socket \
  /run/docker.sock \
  /var/run/docker.sock \
  /run/podman \
  /run/libvirt \
  /tmp/.X11-unix \
  /tmp/.ICE-unix \
  "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"; do
  __cs_mask "$p"
done

# Credential stores, masked at both their conventional and their XDG-relocated
# locations. shell/xdg.sh relocates more of these than the previous list
# covered: GNUPGHOME, AWS_CONFIG_FILE, DOCKER_CONFIG, KUBECONFIG and
# NPM_CONFIG_USERCONFIG all move under ~/.config there, and __create_xdg_dirs
# creates them, so naming only the legacy dotdirs masks nothing.
# ~/.mozilla is included because cookies.sqlite is plaintext SQLite — live
# sessions for every logged-in site, no decryption needed.
# The password store IS listed, despite the ciphertext being safe and $GNUPGHOME
# being masked: `ls -R` over it returns nix/github-token.gpg, cachix/authtoken.gpg,
# OPENAI_API_KEY.gpg — a precise index of which secrets exist and what they are
# for, which turns any gap in this list into a directed search. Masking it costs
# nothing, since `pass` cannot decrypt inside the namespace anyway.
# Shell history is listed for the same reason it is worth reading: exported
# tokens, one-off curl calls with bearer headers, and psql URLs live there.
__cs_creds=(
  "$HOME/.aws"
  "${AWS_CONFIG_FILE:-}"
  "${AWS_SHARED_CREDENTIALS_FILE:-}"
  "${XDG_CONFIG_HOME:-$HOME/.config}/aws"
  "$HOME/.gnupg"
  "${GNUPGHOME:-}"
  "${XDG_CONFIG_HOME:-$HOME/.config}/gnupg"
  "${CLOUDSDK_CONFIG:-}"
  "$HOME/.config/gcloud"
  "${NETRC:-}"
  "$HOME/.netrc"
  "${DOCKER_CONFIG:-}"
  "$HOME/.docker"
  "${KUBECONFIG:-}"
  "$HOME/.kube"
  "${NPM_CONFIG_USERCONFIG:-}"
  "$HOME/.npmrc"
  "$HOME/.git-credentials"
  "$HOME/.terraform.d"
  "$HOME/.pki"
  "${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
  "$HOME/.mozilla"
  "$HOME/.thunderbird"
  "$HOME/.config/chromium"
  "$HOME/.config/google-chrome"
  "$HOME/.config/BraveSoftware"
  # Gemini CLI OAuth token store, plus nix's access-tokens include — a GitHub PAT
  # in cleartext that otherwise defeats the ~/.config/gh mask below. nix.conf
  # keeps working: it only !include's this file, and an empty include is valid.
  "$HOME/.gemini"
  "${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix-access-tokens.conf"
  # cachix holds a binary-cache push token, which is a code-execution path and
  # not merely a credential: this host substitutes from that cache.
  "${XDG_CONFIG_HOME:-$HOME/.config}/cachix"
  "${XDG_DATA_HOME:-$HOME/.local/share}/pki"
  "$HOME/.gmailctl"
  "$HOME/.supabase"
  # npm/yeoman-style tools drop OAuth tokens here under per-tool names.
  "${XDG_CONFIG_HOME:-$HOME/.config}/configstore"
  # VS Code's secret store: extension tokens (GitHub, Azure, database creds).
  "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/globalStorage"
  "${PASSWORD_STORE_DIR:-$HOME/.password-store}"
  "${HISTFILE:-}"
  "$HOME/.bash_history"
  "$HOME/.zsh_history"
  "${XDG_DATA_HOME:-$HOME/.local/share}/zsh/history"
)
# An `ask` rule on Bash(gh *) never gated this: the Read tool opens hosts.yml
# directly, `cat ~/.config/gh/hosts.yml` does not match the pattern, and hooks
# and MCP servers — the components this wrapper exists to contain — bypass the
# permission layer entirely. Masked by default; opt in per session when a task
# genuinely needs the gh CLI.
if [ "${CLAUDE_SANDBOX_ALLOW_GH:-0}" = "1" ]; then
  echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_GH=1 — ~/.config/gh readable; its OAuth token is reachable by any code in the sandbox" >&2
else
  __cs_creds+=("${GH_CONFIG_DIR:-$HOME/.config/gh}")
fi
for p in "${__cs_creds[@]}"; do
  [ -n "$p" ] && __cs_mask "$p"
done

# Sibling Claude profiles. Only the active $CLAUDE_CONFIG_DIR is in scope (bound
# rw above); every other ~/.claude* profile — and the legacy ~/.claude.json index
# in $HOME — holds another session's .credentials.json (live OAuth tokens) and
# history this session never needs. With the network open, readable means
# exfiltratable, so mask all of them bar the active profile.
__cs_active_claude="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
[ -d "$__cs_active_claude" ] && __cs_active_claude=$(readlink -f "$__cs_active_claude")
for d in "$HOME"/.claude*; do
  [ -e "$d" ] || continue
  [ "$(readlink -f "$d")" = "$__cs_active_claude" ] && continue
  # Default layout (no CLAUDE_CONFIG_DIR): the active index lives at ~/.claude.json
  # in $HOME, not under the profile dir — never mask it there.
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ "$d" = "$HOME/.claude.json" ] && continue
  __cs_mask "$d"
done

# Stock ssh_config files Include other root-owned files (NixOS: a systemd store
# path; Debian/Fedora/Arch: /etc/ssh/ssh_config.d/*). Inside the user namespace
# root maps to the overflow uid and OpenSSH hard-fails on Include'd files it
# considers badly owned ("Bad owner or permissions"), which would break ssh for
# every namespaced process. Rather than chasing each Include target (indented
# lines, several targets per line, globs), bind a user-owned copy of the file
# with the Include lines stripped.
# Bind onto the *resolved* path, not /etc/ssh/ssh_config itself: on NixOS that
# is a symlink chain (/etc/static/ssh/... -> /nix/store/...-etc-ssh-ssh_config),
# and bwrap resolves a bind destination before mounting, so targeting the
# symlink aborts namespace setup with "Can't create file at
# /etc/ssh/ssh_config". readlink -f is a no-op where the file is real.
if [ -f /etc/ssh/ssh_config ]; then
  __cs_etc_ssh=$(readlink -f /etc/ssh/ssh_config)
  sed -E '/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]([[:space:]=]|$)/d' \
    /etc/ssh/ssh_config >"$__cs_tmp/etc_ssh_config"
  args+=(--ro-bind "$__cs_tmp/etc_ssh_config" "$__cs_etc_ssh")
fi

# Replace ~/.ssh with a sanitized copy: config plus everything it Includes from
# inside ~/.ssh, known_hosts, and one public key per IdentityFile. ssh still
# authenticates through the agent socket (re-bound below), outside the
# namespace, so private keys never enter it. When the agent holds no identity
# the sanitized tree simply lacks usable keys — auth fails loudly instead of
# falling back to exposing the real ~/.ssh (the repo agent runs `ssh-agent -t
# 2h`, so an empty agent is routine here, not exceptional).
if [ -d "$HOME/.ssh" ]; then
  mkdir -p "$__cs_tmp/ssh"
  for f in known_hosts known_hosts2; do
    [ -f "$HOME/.ssh/$f" ] && cp "$HOME/.ssh/$f" "$__cs_tmp/ssh/$f"
  done

  # Collect config files to scan: ~/.ssh/config and, transitively, every
  # Include target. Targets under ~/.ssh are copied at their relative path
  # (the bind below would otherwise make them vanish inside the namespace);
  # targets elsewhere stay readable through the read-only root. Tokens are
  # ~-expanded and relative ones resolved against ~/.ssh, as ssh does; globs
  # expand naturally.
  # Split an ssh_config argument list into tokens, honouring the double quotes
  # ssh uses around paths that contain spaces. `read -r -a` could not: it splits
  # on IFS, so `Include "my confs/*"` arrived as two broken targets — and where
  # $HOME itself contains a space, every relative Include was silently dropped.
  __cs_split() {
    local line="$1" tok="" ch quoted=0 i
    __cs_out=()
    for ((i = 0; i < ${#line}; i++)); do
      ch="${line:i:1}"
      case "$ch" in
        '"') if [ "$quoted" -eq 1 ]; then quoted=0; else quoted=1; fi ;;
        ' ' | $'\t')
          if [ "$quoted" -eq 1 ]; then
            tok+="$ch"
          elif [ -n "$tok" ]; then
            __cs_out+=("$tok")
            tok=""
          fi
          ;;
        *) tok+="$ch" ;;
      esac
    done
    if [ -n "$tok" ]; then __cs_out+=("$tok"); fi
    return 0
  }

  __cs_ssh_real=$(readlink -m "$HOME/.ssh")
  __cs_cfgs=()
  __cs_queue=()
  __cs_trunc=0
  declare -A __cs_seen=()
  if [ -f "$HOME/.ssh/config" ]; then
    cp "$HOME/.ssh/config" "$__cs_tmp/ssh/config"
    __cs_cfgs+=("$HOME/.ssh/config")
    __cs_queue+=("$HOME/.ssh/config")
    __cs_seen["$(readlink -m "$HOME/.ssh/config")"]=1
  fi
  while [ "${#__cs_queue[@]}" -gt 0 ]; do
    __cs_cfg="${__cs_queue[0]}"
    __cs_queue=("${__cs_queue[@]:1}")
    while IFS= read -r __cs_line; do
      __cs_split "$__cs_line"
      for __cs_t in "${__cs_out[@]}"; do
        # shellcheck disable=SC2088 # matching a literal ~/ token, as ssh writes it
        case "$__cs_t" in
          "~/"*) __cs_t="$HOME/${__cs_t#"~/"}" ;;
          /*) ;;
          *) __cs_t="$HOME/.ssh/$__cs_t" ;;
        esac
        # shellcheck disable=SC2086 # unquoted on purpose: Include supports globs
        for __cs_f in $__cs_t; do
          [ -f "$__cs_f" ] || continue
          # Canonicalised before anything is done with it. A relative Include is
          # concatenated onto ~/.ssh by plain string arithmetic above, so
          # `Include ../../../../elsewhere/x` walks straight out of it — and the
          # copy below would then mkdir and cp outside the workspace. Resolving
          # first makes the containment test mean what it says, and doubles as
          # the dedup key so two spellings of one file collapse to one entry.
          __cs_real=$(readlink -m "$__cs_f")
          [ -z "${__cs_seen["$__cs_real"]:-}" ] || continue
          __cs_seen["$__cs_real"]=1
          # Checked per file rather than per queue-pop: the old bound let a
          # single config with 70 top-level Includes collect all of them and then
          # expand none of their nested ones, silently.
          if [ "${#__cs_cfgs[@]}" -ge 64 ]; then
            __cs_trunc=1
            continue
          fi
          case "$__cs_real/" in
            "$__cs_ssh_real/"*)
              __cs_rel="${__cs_real#"$__cs_ssh_real/"}"
              mkdir -p "$__cs_tmp/ssh/$(dirname "$__cs_rel")"
              cp "$__cs_real" "$__cs_tmp/ssh/$__cs_rel"
              ;;
          esac
          __cs_cfgs+=("$__cs_real")
          __cs_queue+=("$__cs_real")
        done
      done
    done < <(sed -nE 's/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]=]+//p' "$__cs_cfg")
  done
  if [ "$__cs_trunc" -eq 1 ]; then
    echo "claude-sandbox: more than 64 ssh config files reachable from ~/.ssh/config; the remainder were not copied, so ssh may resolve some hosts differently inside the sandbox" >&2
  fi

  # One public key per IdentityFile. Prefer the identity's own .pub from the
  # real ~/.ssh; fall back to the agent listing only when the choice is
  # unambiguous — dumping a multi-key `ssh-add -L` into every .pub would make
  # ssh present the same first key for every host (and on services that map
  # keys to accounts, authenticate as the wrong identity).
  __cs_agent=$(ssh-add -L 2>/dev/null) || __cs_agent=""
  __cs_agent_n=0
  [ -n "$__cs_agent" ] && __cs_agent_n=$(printf '%s\n' "$__cs_agent" | grep -c .)
  if [ "${#__cs_cfgs[@]}" -gt 0 ]; then
    while IFS= read -r __cs_id; do
      [ -n "$__cs_id" ] || continue
      # shellcheck disable=SC2088 # matching a literal ~/ token, as ssh writes it
      case "$__cs_id" in
        "~/"*) __cs_id="$HOME/${__cs_id#"~/"}" ;;
        /*) ;;
        *) continue ;; # %-tokens / cwd-relative names: not resolvable here
      esac
      case "$__cs_id" in
        "$HOME/.ssh/"*)
          __cs_dst="$__cs_tmp/ssh/${__cs_id#"$HOME/.ssh/"}.pub"
          mkdir -p "$(dirname "$__cs_dst")"
          ;;
        *)
          # Identity outside ~/.ssh: the private key would stay readable through
          # the read-only root — mask it. Its real .pub (if any) is still
          # visible, so agent auth keeps working for that host.
          __cs_mask "$__cs_id"
          continue
          ;;
      esac
      [ -e "$__cs_dst" ] && continue
      if [ -f "$__cs_id.pub" ]; then
        cp "$__cs_id.pub" "$__cs_dst"
      elif [ "$__cs_agent_n" -eq 1 ]; then
        printf '%s\n' "$__cs_agent" >"$__cs_dst"
      elif [ "$__cs_agent_n" -gt 1 ]; then
        # Disambiguate by the agent comment, which is usually the key's path.
        __cs_match=$(printf '%s\n' "$__cs_agent" | grep -F "$(basename "$__cs_id")" || true)
        if [ -n "$__cs_match" ] && [ "$(printf '%s\n' "$__cs_match" | grep -c .)" -eq 1 ]; then
          printf '%s\n' "$__cs_match" >"$__cs_dst"
        else
          echo "claude-sandbox: no unambiguous agent key for $__cs_id (no .pub beside it, $__cs_agent_n agent keys); skipping" >&2
        fi
      else
        # No .pub beside the key and nothing in the agent to reconstruct one
        # from: this identity gets no stub, so a later ssh-add cannot rescue it
        # either. The only unfixable-mid-session case, hence the only warning —
        # an empty agent alone is not one, since the stub makes ssh-add work at
        # any point in the session.
        echo "claude-sandbox: no public key for $__cs_id (no .pub beside it, agent empty); ssh with this identity cannot work this session — create the .pub or ssh-add before launching" >&2
      fi
    done < <(
      sed -nE 's/^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]=]+//p' \
        "${__cs_cfgs[@]}" | sed -E 's/^"//; s/"$//' | sort -u
    )
  fi

  args+=(--ro-bind "$__cs_tmp/ssh" "$HOME/.ssh")

  # If the agent socket itself lives under ~/.ssh, give the sanitized tree a
  # mountpoint for the re-bind below — bwrap cannot create one through a
  # read-only mount and would abort namespace setup.
  case "${SSH_AUTH_SOCK:-}" in
    "$HOME/.ssh/"*)
      __cs_rel="${SSH_AUTH_SOCK#"$HOME/.ssh/"}"
      mkdir -p "$__cs_tmp/ssh/$(dirname "$__cs_rel")"
      : >"$__cs_tmp/ssh/$__cs_rel"
      ;;
  esac
fi

# The agent socket is the one deliberate unix-socket channel into the
# namespace; re-bind it on top of the masks above (its usual homes — /tmp/ssh-*
# here, $XDG_RUNTIME_DIR elsewhere — are shared and tmpfs-masked respectively).
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  args+=(--bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
fi

# Fail ioctl(TIOCSTI/TIOCLINUX) with EPERM. bwrap keeps the launching terminal
# as the controlling tty (--new-session would drop it, and with it the TUI's
# SIGWINCH), so without this filter the namespace can push characters into that
# terminal's input queue and the host shell executes them after claude exits —
# CVE-2017-5226. The kernel is no backstop: LEGACY_TIOCSTI still defaults to y
# upstream, and dev.tty.legacy_tiocsti is 1 on this host.
# Emitted as raw cBPF (what bwrap's --seccomp expects, i.e. seccomp_export_bpf
# format): struct sock_filter { u16 code; u8 jt; u8 jf; u32 k; }, little-endian.
__cs_bpf() {
  printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' \
    $(($1 & 0xff)) $((($1 >> 8) & 0xff)) "$2" "$3" \
    $(($4 & 0xff)) $((($4 >> 8) & 0xff)) $((($4 >> 16) & 0xff)) $((($4 >> 24) & 0xff)))"
}
# Native arch + its 32-bit compat arch, with ioctl's syscall number under each.
# BOTH must be filtered: a 32-bit process reports the *compat* arch in
# seccomp_data.arch (x86_64→i386, arm64→arm), so a filter that recognises only
# the native arch and then ALLOWs waves that process straight through — the exact
# TIOCSTI escape this filter exists to close (CVE-2017-5226), trivially reachable
# on any kernel with the compat ABI compiled in (here CONFIG_IA32_EMULATION=y).
__cs_seccomp_arch="" __cs_seccomp_carch=""
case "$(uname -m)" in
  x86_64)
    __cs_seccomp_arch=$((0xC000003E)) __cs_nr_ioctl=16
    __cs_seccomp_carch=$((0x40000003)) __cs_nr_ioctl_c=54
    ;; # AUDIT_ARCH_I386
  aarch64)
    __cs_seccomp_arch=$((0xC00000B7)) __cs_nr_ioctl=29
    __cs_seccomp_carch=$((0x40000028)) __cs_nr_ioctl_c=54
    ;; # AUDIT_ARCH_ARM
esac
if [ -n "$__cs_seccomp_arch" ]; then
  {
    # cBPF over seccomp_data. args[] are 64-bit slots at fixed offsets whatever
    # the calling ABI, so the TIOCSTI/TIOCLINUX request compare is shared; only
    # ioctl's syscall number differs per ABI. Instruction indices are noted
    # because jt/jf are relative jumps that must land exactly. Unknown arch still
    # ALLOWs (a genuine other-arch multi-arch binary, not the compat bypass,
    # which is now handled explicitly).
    __cs_bpf $((0x20)) 0 0 4                     # 0:  A = arch
    __cs_bpf $((0x15)) 2 0 "$__cs_seccomp_arch"  # 1:  ==native → native nr-check (4)
    __cs_bpf $((0x15)) 4 0 "$__cs_seccomp_carch" # 2:  ==compat → compat nr-check (7)
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))       # 3:  other arch → ALLOW
    __cs_bpf $((0x20)) 0 0 0                     # 4:  A = syscall nr
    __cs_bpf $((0x15)) 4 0 "$__cs_nr_ioctl"      # 5:  ==ioctl → request-check (10)
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))       # 6:  not ioctl → ALLOW
    __cs_bpf $((0x20)) 0 0 0                     # 7:  A = syscall nr
    __cs_bpf $((0x15)) 1 0 "$__cs_nr_ioctl_c"    # 8:  ==ioctl(compat) → request-check (10)
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))       # 9:  not ioctl → ALLOW
    __cs_bpf $((0x20)) 0 0 24                    # 10: A = args[1], the ioctl request
    __cs_bpf $((0x15)) 2 0 $((0x5412))           # 11: TIOCSTI → block (14)
    __cs_bpf $((0x15)) 1 0 $((0x541C))           # 12: TIOCLINUX → block (14)
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))       # 13: other request → ALLOW
    __cs_bpf $((0x06)) 0 0 $((0x00050001))       # 14: SECCOMP_RET_ERRNO | EPERM
  } >"$__cs_tmp/seccomp.bpf"
  # A numeric fd, so it survives the exec into bwrap.
  exec 9<"$__cs_tmp/seccomp.bpf"
  args+=(--seccomp 9)
else
  echo "claude-sandbox: no seccomp filter for $(uname -m); TIOCSTI injection into the launching terminal is not blocked" >&2
fi

# The nix-daemon socket stays reachable by design (see the header). For a client
# the daemon trusts, that is equivalent to root on the host: trusted clients may
# set post-build-hook and friends, which the root daemon then executes. Nothing
# in this namespace can prevent that, so say so plainly rather than implying the
# boundary holds.
if command -v nix >/dev/null 2>&1; then
  __cs_trusted=$(nix config show trusted-users 2>/dev/null || nix show-config trusted-users 2>/dev/null || true)
  __cs_tu=0
  case " $__cs_trusted " in
    *" $(id -un) "* | *" * "*) __cs_tu=1 ;;
  esac
  # Every group, not just the primary one. `id -gn` reports only the primary
  # group, so the ordinary arrangement — @wheel granted as a *secondary* group,
  # which is how NixOS's users.users.<name>.extraGroups puts it there — produced
  # no warning at all on exactly the hosts most likely to be affected.
  if [ "$__cs_tu" -eq 0 ]; then
    for __cs_g in $(id -Gn); do
      case " $__cs_trusted " in
        *" @$__cs_g "*)
          __cs_tu=1
          break
          ;;
      esac
    done
  fi
  if [ "$__cs_tu" -eq 1 ]; then
    echo "claude-sandbox: WARNING — $(id -un) is a nix trusted-user, so the nix-daemon socket is a root-equivalent escape from this sandbox. Remove the user from nix.settings.trusted-users to close it." >&2
  fi
fi

# tmux derives pane_current_command from /proc/<fg pgid>/cmdline, and window
# autorename plus the M-w/M-W save/restore flows key off it being the payload
# name ("claude"), so this process must exec into bwrap rather than stay
# resident as its parent — but an EXIT trap cannot survive an exec. Hand
# cleanup to a detached watcher and exec bwrap under the payload's name.
trap - EXIT
(
  trap '' HUP INT TERM
  while kill -0 $$ 2>/dev/null; do sleep 15; done
  rm -rf "$__cs_tmp"
) &
exec -a "$(basename "$1")" bwrap "${args[@]}" -- "$@"
rm -rf "$__cs_tmp"
echo "claude-sandbox: failed to exec bwrap" >&2
exit 127
