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
#     --ro-bind wins): $PWD/.direnv/bin, direnv's source_url CAS,
#     $PWD/.git/{hooks,config} and lefthook*.yml. Writing one line into any of
#     them is host code execution on the user's next cd or commit, which would
#     undo every mask below. This is a named list, not a guarantee about the
#     whole cwd: flake.nix and devshells/ stay writable because editing them is
#     the point of the repo; what keeps a poisoned shellHook off the host is
#     nix-direnv's manual-reload mode, set in $PERMEANCE_TREE's direnvrc, which
#     turns a changed flake into a notice plus an explicit `nix-direnv-reload`
#     instead of a silent re-evaluation on the next cd.
#   - $PERMEANCE_TREE — the live sources/ tree — is bound read-write. This is
#     the one deliberate hole in the rule above, and the widest: every host
#     shell sources .zshrc and functions/*.sh from it, the tmux config
#     run-shells ~50 paths in it, DIRENV_CONFIG points at its direnvrc (which
#     direnv's allow-hash does not cover), and claude.bash executes this very
#     launcher from it. So a sandboxed session can rewrite the host's shell
#     config, and this boundary for the next launch, and the host runs what it
#     wrote at the next shell. The tree is git-tracked: review is
#     `git diff -- sources` and undo is `git checkout -- sources`, both on the
#     host, both after the fact. An overlay with a host-side review step held
#     this line until 2026-09-18 and was dropped as too much workflow for a
#     config repo; git history has it. Bundled mode resolves $PERMEANCE_TREE
#     to a root-owned store path, read-only however it is bound, so nothing is
#     bound there. One file is re-pinned read-only from the host copy on top
#     of the bind: .claude/git-allowlist.toml, which the git-shim re-reads on
#     every call — a writable copy would let a session widen its own allowlist
#     mid-run. It is edited from a plain terminal.
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
# Refuse the cwd as the writable region when it *contains* $HOME, an XDG
# config/data root, or ~/.local (binding that read-write hands the namespace the
# whole home directory — a no-op sandbox), or when it is *inside* a tree the
# desktop session executes at login (~/.config/systemd, ~/.config/autostart,
# ~/.local/share/{systemd,applications}, ~/.local/bin), where read-write access is
# host code execution at the next login. The comparison is the *physical* cwd
# (cd -P above) against readlink -m'd sensitive dirs; that logic, and the refusal
# messages, live in claude-cwd-gate (see packages/custom/claude-cwd-gate), which
# exits 64 with the reason on a refusal. Fail closed: any non-zero exit (including
# the binary missing) aborts rather than bind a possibly-unsafe cwd read-write.
claude-cwd-gate \
  --pwd "$PWD" \
  --home "$HOME" \
  --config "${XDG_CONFIG_HOME:-$HOME/.config}" \
  --data "${XDG_DATA_HOME:-$HOME/.local/share}" || exit "$?"

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
# weaker next sandbox ($PERMEANCE_TREE would head this list; it is the one
# region left writable on purpose — see the header and the bind below):
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
# Unconditional locks. No flag lifts these, and the writable $PERMEANCE_TREE
# below does not reach them: a session editing shell config never needs
# .git/hooks or lefthook.yml, so opening those alongside would only widen the
# boundary for no gain.
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
# is the repo's purpose — so a poisoned shellHook could reach the host through
# direnv's re-evaluation (.envrc is self-guarding via direnv's allow-hash;
# flake.nix is not). That path is closed in $PERMEANCE_TREE's direnvrc, which
# puts nix-direnv in manual-reload mode: an outdated flake keeps the cached env
# and prints a notice, and `nix-direnv-reload` — generated into $PWD/.direnv/bin,
# relocked above — is the human step.
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

# The live sources tree, bound read-write: the one host-executed region this
# file leaves open (see the header). Bound explicitly rather than merely left
# unlocked, and after the relocks above so it wins over anything that happens
# to contain it: the tree sits inside the writable cwd only when launching from
# the repo that holds it, and from any other project the root read-only bind
# would cover it. Bundled mode resolves $PERMEANCE_TREE to a store path —
# root-owned and read-only however it is bound — so nothing is bound there;
# edits need a working tree, reached by launching with PERMEANCE_ROOT set.
# .claude/git-allowlist.toml is re-pinned from the host copy on top of the
# bind: the git-shim re-reads it on every call, and a writable copy would let a
# session widen its own allowlist mid-run. It is edited from a plain terminal.
case "${PERMEANCE_TREE:-}" in
  "")
    echo "claude-sandbox: WARNING — PERMEANCE_TREE is unset; git-allowlist.toml cannot be pinned, and the shell config tree is writable wherever the cwd bind covers it" >&2
    ;;
  /nix/store/*) ;;
  *)
    if [ -d "$PERMEANCE_TREE" ]; then
      args+=(--bind "$PERMEANCE_TREE" "$PERMEANCE_TREE")
      if [ -f "$PERMEANCE_TREE/.claude/git-allowlist.toml" ]; then
        args+=(--ro-bind "$PERMEANCE_TREE/.claude/git-allowlist.toml" "$PERMEANCE_TREE/.claude/git-allowlist.toml")
      fi
    else
      echo "claude-sandbox: WARNING — PERMEANCE_TREE '$PERMEANCE_TREE' is not a directory; nothing bound" >&2
    fi
    ;;
esac
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

# Firebase CLI auth. CLAUDE_SANDBOX_ALLOW_FIREBASE=1 (leader alias `cf`) mounts a
# scoped service-account key as Application Default Credentials, NOT your personal
# `firebase login` OAuth token — that token stays masked (configstore is in the
# creds list above), so firebase-tools can only act with the least-privilege SA.
# The key is read from `pass` (entry $__cs_fb_pass), decrypted here on the host —
# where gpg-agent is reachable, exactly like the MCP `$(pass show …)` secrets — and
# written to the private workspace, bound read-only over the masked gcloud dir
# (later bind wins) so its siblings stay hidden. Read-only is safe: unlike the
# personal token, an SA key is static (short-lived access tokens are minted in
# memory), so a refresh never writes it back — but note the exfiltratable artifact
# is a *permanent* private key: scoped by the SA's roles, yet valid until revoked,
# not merely until a token expires. Hence per-session opt-in, like ALLOW_GH.
#
# firebase-tools' auth precedence is FIREBASE_TOKEN → configstore login → ADC
# (GOOGLE_APPLICATION_CREDENTIALS). Masking configstore forces the SA path; a
# FIREBASE_TOKEN inherited from the launching shell would outrank it and both defeat
# the scoping and ride in exfiltratable, so it and the gcloud access-token overrides
# are unset below whenever the SA is mounted (bwrap inherits the env otherwise).
#
# Two operational facts, because their failures read as auth bugs, not config gaps:
#   - No project is selected here. firebase resolves the active project from
#     `--project <id>` or a repo `.firebaserc` ONLY — never $GOOGLE_CLOUD_PROJECT nor
#     the key's own project_id — so most commands need an explicit --project.
#   - The key must carry the IAM roles for the task. One scoped key is realistic for
#     reads + Hosting (roles/firebase.viewer + firebasehosting.admin +
#     datastore.viewer); `deploy --only functions` needs far more (Cloud Build,
#     Artifact Registry, iam.serviceAccountUser, …), so a PERMISSION_DENIED there is
#     a missing role, not a broken login. (v15 also prints "have you run firebase
#     login?" on a credential *timeout* — under this setup that means slow
#     token/role/project, not a missing login.)
# Only firebase reads GOOGLE_APPLICATION_CREDENTIALS (via ADC); `gcloud` itself uses
# its own credential store and is NOT authenticated by this key.
__cs_fb_pass="${FIREBASE_SA_KEY_PASS:-firebase/sa-key}"
if [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ]; then
  if ! command -v pass >/dev/null 2>&1; then
    echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but 'pass' is not on PATH; cannot read the SA key" >&2
  elif [ -z "$__cs_xdg" ]; then
    # No per-user runtime dir, so the private workspace fell back to $HOME/.cache on
    # persistent disk (see __cs_ws_parent above). Refuse rather than write a
    # long-lived plaintext SA key to disk, where a crash or reboot could strand it:
    # restart tmux so the pane inherits XDG_RUNTIME_DIR (or export it), then retry.
    echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but no RAM-backed runtime dir; refusing to write the SA key to disk. Restart tmux or set XDG_RUNTIME_DIR, then retry." >&2
  elif ! __cs_fb_key=$(pass show "$__cs_fb_pass" 2>/dev/null) || [ -z "$__cs_fb_key" ]; then
    echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but no key at 'pass show $__cs_fb_pass'; store the scoped service-account JSON there first (pass insert -m $__cs_fb_pass)" >&2
  else
    # Reject anything that is not a service-account key JSON before mounting it, so a
    # wrong `pass` entry (a bare token, or a password-first multiline note) fails here
    # with a clear message instead of an opaque parse error inside firebase-tools.
    case "$__cs_fb_key" in
      *'"private_key"'*'"client_email"'* | *'"client_email"'*'"private_key"'*)
        mkdir -p "$__cs_tmp/gcloud"
        (
          umask 077
          printf '%s\n' "$__cs_fb_key" >"$__cs_tmp/gcloud/firebase-sa.json"
        )
        unset __cs_fb_key
        args+=(--ro-bind "$__cs_tmp/gcloud" "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}")
        args+=(--setenv GOOGLE_APPLICATION_CREDENTIALS "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/firebase-sa.json")
        # Enforce "only the least-privilege SA": drop the higher-precedence credential
        # channels bwrap would otherwise inherit, so neither overrides the SA nor is
        # left readable/exfiltratable inside the open-network namespace.
        args+=(--unsetenv FIREBASE_TOKEN)
        args+=(--unsetenv GOOGLE_OAUTH_ACCESS_TOKEN)
        args+=(--unsetenv CLOUDSDK_AUTH_ACCESS_TOKEN)
        # firebase-tools caches its MOTD/remote-config and update check under
        # ~/.config/configstore; $HOME is read-only in here, so those writes fail and
        # abort the CLI with a spurious "unexpected error" and non-zero exit even when
        # the command succeeded. Give it a fresh writable tmpfs at the XDG-correct path
        # (matching the mask above; later bind wins) — a tmpfs, not a persistent dir,
        # so a stray or planted firebase-tools.json token cannot survive to outrank the
        # SA next session (configstore > ADC above). Cost: the MOTD cache is not reused
        # across sessions, which is noise.
        args+=(--tmpfs "${XDG_CONFIG_HOME:-$HOME/.config}/configstore")
        echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 — scoped firebase SA key (pass: $__cs_fb_pass) mounted as ADC; readable by any code in this session" >&2
        ;;
      *)
        unset __cs_fb_key
        echo "claude-sandbox: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but 'pass show $__cs_fb_pass' is not a service-account key JSON (needs private_key + client_email); not mounting" >&2
        ;;
    esac
  fi
fi

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
# inside ~/.ssh, known_hosts, and one public key per IdentityFile — never a
# private key. ssh still authenticates through the agent socket (re-bound below),
# outside the namespace, so the sanitized tree needs only public material. When
# the agent holds no identity the tree simply lacks usable keys — auth fails
# loudly rather than falling back to exposing the real ~/.ssh (the repo agent runs
# `ssh-agent -t 2h`, so an empty agent is routine here, not exceptional).
#
# The walk — Include directives (globs, dedup, the containment check that stops a
# crafted `Include ../x` writing outside the tree, a 64-file cap) and each
# IdentityFile resolved to a public key with an agent-listing fallback — lives in
# claude-ssh-sanitize (see packages/custom/claude-ssh-sanitize). It prints the
# private keys that live OUTSIDE ~/.ssh, one per line, for us to mask over the
# read-only root. Fail closed, like the seccomp gate above: if the helper is
# missing or errors, refuse to launch rather than let the read-only root expose
# the real ~/.ssh — its private keys — inside the namespace.
if [ -d "$HOME/.ssh" ]; then
  if ! __cs_ssh_masks=$(claude-ssh-sanitize \
    --home "$HOME" --src "$HOME/.ssh" --dst "$__cs_tmp/ssh" \
    --auth-sock "${SSH_AUTH_SOCK:-}"); then
    echo "claude-sandbox: could not sanitize ~/.ssh — claude-ssh-sanitize is missing from PATH or failed. Refusing to launch, because the read-only root would otherwise expose your real ~/.ssh (private keys) inside the namespace. Rebuild the terminal so its tools env carries claude-ssh-sanitize, or set CLAUDE_SANDBOX=0 to launch unsandboxed." >&2
    exit 1
  fi
  while IFS= read -r __cs_m; do
    [ -n "$__cs_m" ] && __cs_mask "$__cs_m"
  done <<<"$__cs_ssh_masks"
  args+=(--ro-bind "$__cs_tmp/ssh" "$HOME/.ssh")
fi

# The agent socket is the one deliberate unix-socket channel into the
# namespace; re-bind it on top of the masks above (its usual homes — /tmp/ssh-*
# here, $XDG_RUNTIME_DIR elsewhere — are shared and tmpfs-masked respectively).
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  args+=(--bind "$SSH_AUTH_SOCK" "$SSH_AUTH_SOCK")
fi

# Fail ioctl(TIOCSTI/TIOCLINUX) with EPERM so a process in the namespace cannot
# push characters into the launching terminal's input queue (CVE-2017-5226) for
# the host shell to run once claude exits. bwrap keeps the launching terminal as
# the controlling tty (--new-session would drop it, and with it the TUI's
# SIGWINCH), and the kernel is no backstop — dev.tty.legacy_tiocsti is 1 here.
# claude-seccomp-bpf (a libseccomp binary; see packages/custom/claude-seccomp-bpf)
# emits the filter in the seccomp_export_bpf format --seccomp expects, covering
# the native and 32-bit compat ABI both, so a compat-arch call can't slip past.
# Passed to bwrap on a numeric fd, which survives the exec into bwrap below.
#
# Required, so it fails closed like the bwrap check at the top of this file: if
# claude-seccomp-bpf is missing from PATH (a tools env built before it was added)
# or emits nothing, refuse to launch rather than run claude with the terminal
# open to injection. There is deliberately no in-place fallback — --new-session
# would also close the hole but costs the TUI its controlling terminal, which is
# the whole reason this filter exists — so the only safe move left is to stop.
if ! claude-seccomp-bpf >"$__cs_tmp/seccomp.bpf" 2>/dev/null || [ ! -s "$__cs_tmp/seccomp.bpf" ]; then
  echo "claude-sandbox: could not emit the TIOCSTI/TIOCLINUX seccomp filter for $(uname -m) — claude-seccomp-bpf is missing from PATH or produced no output. Refusing to launch, because without it a process in the namespace can inject characters into the launching terminal (CVE-2017-5226) that the host shell runs once claude exits. Rebuild the terminal so its tools env carries claude-seccomp-bpf, or set CLAUDE_SANDBOX=0 to launch unsandboxed." >&2
  exit 1
fi
exec 9<"$__cs_tmp/seccomp.bpf"
args+=(--seccomp 9)

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
