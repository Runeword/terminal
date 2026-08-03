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
#   - anything the *host* shell later executes or sources is re-pinned read-only
#     on top of those writable regions (bwrap applies binds in order, so a later
#     --ro-bind wins). Without that, writing one line into $PERMEANCE_TREE's
#     direnvrc/zshrc, $PWD/.direnv/bin, or direnv's source_url CAS is host code
#     execution on the user's next cd — which would undo every mask below.
#     CLAUDE_SANDBOX_UNLOCK_CONFIG=1 lifts the lock for sessions that are
#     deliberately editing shell config; it is a conscious, per-session choice.
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
case "$HOME/" in
  "${PWD%/}/"*)
    echo "claude-sandbox: refusing to bind $PWD read-write — it contains \$HOME; run from a project directory (or CLAUDE_SANDBOX=0 to launch unsandboxed)" >&2
    exit 64
    ;;
esac

# Workspace for the sanitized copies and mask sources. Deliberately NOT under
# /tmp: /tmp is bind-mounted read-write into the namespace, so a workspace
# there could be rewritten by the sandboxed process through its real path,
# bypassing every read-only bind built from it. $XDG_RUNTIME_DIR is masked by
# a private tmpfs inside the namespace, and ~/.cache stays read-only inside,
# so either parent keeps the workspace unreachable-or-immutable.
__cs_ws_parent="${XDG_RUNTIME_DIR:-}"
[ -n "$__cs_ws_parent" ] && [ -d "$__cs_ws_parent" ] || __cs_ws_parent="$HOME/.cache"
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
__cs_relock() {
  [ -n "$1" ] && [ -e "$1" ] && args+=(--ro-bind "$1" "$1")
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
if [ "${CLAUDE_SANDBOX_UNLOCK_CONFIG:-0}" = "1" ]; then
  echo "claude-sandbox: CLAUDE_SANDBOX_UNLOCK_CONFIG=1 — shell config is writable; edits to it run on your host, outside this sandbox" >&2
else
  __cs_relock "${PERMEANCE_TREE:-}"
  __cs_relock "$PWD/.direnv"
fi
__cs_relock "${XDG_CACHE_HOME:-$HOME/.cache}/direnv/cas"

# The read-only remount never blocks connect(2), so every host unix socket is
# an escape hatch by default — /var/run/docker.sock alone is root-equivalent,
# and the tmux socket would let the namespace type into host panes. Replace the
# per-user runtime tree with a private tmpfs and mask the rest individually.
# Extend this list when a new daemon socket appears on the host.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  args+=(--perms 0700 --tmpfs "$XDG_RUNTIME_DIR")
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
# PASSWORD_STORE_DIR is not listed: the store is GPG-encrypted and $GNUPGHOME is
# masked, so it is already unreadable.
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
  __cs_cfgs=()
  __cs_queue=()
  __cs_seen=" "
  if [ -f "$HOME/.ssh/config" ]; then
    cp "$HOME/.ssh/config" "$__cs_tmp/ssh/config"
    __cs_cfgs+=("$HOME/.ssh/config")
    __cs_queue+=("$HOME/.ssh/config")
    __cs_seen=" $HOME/.ssh/config "
  fi
  while [ "${#__cs_queue[@]}" -gt 0 ] && [ "${#__cs_cfgs[@]}" -lt 64 ]; do
    __cs_cfg="${__cs_queue[0]}"
    __cs_queue=("${__cs_queue[@]:1}")
    while read -r -a __cs_toks; do
      for __cs_t in "${__cs_toks[@]}"; do
        # shellcheck disable=SC2088 # matching a literal ~/ token, as ssh writes it
        case "$__cs_t" in
          "~/"*) __cs_t="$HOME/${__cs_t#"~/"}" ;;
          /*) ;;
          *) __cs_t="$HOME/.ssh/$__cs_t" ;;
        esac
        # shellcheck disable=SC2086 # unquoted on purpose: Include supports globs
        for __cs_f in $__cs_t; do
          [ -f "$__cs_f" ] || continue
          case "$__cs_seen" in *" $__cs_f "*) continue ;; esac
          __cs_seen="$__cs_seen$__cs_f "
          case "$__cs_f" in
            "$HOME/.ssh/"*)
              __cs_rel="${__cs_f#"$HOME/.ssh/"}"
              mkdir -p "$__cs_tmp/ssh/$(dirname "$__cs_rel")"
              cp "$__cs_f" "$__cs_tmp/ssh/$__cs_rel"
              ;;
          esac
          __cs_cfgs+=("$__cs_f")
          __cs_queue+=("$__cs_f")
        done
      done
    done < <(sed -nE 's/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]=]+//p' "$__cs_cfg")
  done

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
__cs_seccomp_arch=""
case "$(uname -m)" in
  x86_64) __cs_seccomp_arch=$((0xC000003E)) __cs_nr_ioctl=16 ;;
  aarch64) __cs_seccomp_arch=$((0xC00000B7)) __cs_nr_ioctl=29 ;;
esac
if [ -n "$__cs_seccomp_arch" ]; then
  {
    # A=arch; if it is not ours the filter cannot reason about syscall numbers,
    # so allow rather than kill (bwrap sets no_new_privs; a mismatch is a
    # multi-arch binary, not an attack).
    __cs_bpf $((0x20)) 0 0 4
    __cs_bpf $((0x15)) 1 0 "$__cs_seccomp_arch"
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))
    __cs_bpf $((0x20)) 0 0 0 # A = syscall nr
    __cs_bpf $((0x15)) 1 0 "$__cs_nr_ioctl"
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000))
    __cs_bpf $((0x20)) 0 0 24              # A = args[1], the ioctl request
    __cs_bpf $((0x15)) 2 0 $((0x5412))     # TIOCSTI
    __cs_bpf $((0x15)) 1 0 $((0x541C))     # TIOCLINUX
    __cs_bpf $((0x06)) 0 0 $((0x7fff0000)) # SECCOMP_RET_ALLOW
    __cs_bpf $((0x06)) 0 0 $((0x00050001)) # SECCOMP_RET_ERRNO | EPERM
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
  case " $__cs_trusted " in
    *" $(id -un) "* | *" @$(id -gn) "* | *" * "*)
      echo "claude-sandbox: WARNING — $(id -un) is a nix trusted-user, so the nix-daemon socket is a root-equivalent escape from this sandbox. Remove the user from nix.settings.trusted-users to close it." >&2
      ;;
  esac
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
