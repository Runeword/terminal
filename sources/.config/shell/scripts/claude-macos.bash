#!/usr/bin/env bash
# macOS side of the claude credential opt-ins. On Linux every session runs
# through claude-sandbox.bash (bubblewrap), which also hands over the
# credentials a session opted into. macOS has Claude Code's own Seatbelt
# sandbox instead (settings.darwin.json), so claude.bash puts this script in
# front of claude only when a session opts into one:
#   CLAUDE_SANDBOX_ALLOW_JIRA=1      (leader `cj`)  claude's Jira API token
#   CLAUDE_SANDBOX_ALLOW_FIREBASE=1  (leader `cf`)  the scoped firebase SA key
# Same pass entries, overrides, checks and messages as the Linux launcher,
# where the rationale for each lives (CLAUDE_SANDBOX_ALLOW_JIRA and
# CLAUDE_SANDBOX_ALLOW_FIREBASE in claude-sandbox.bash). The credential is
# decrypted here, on the host: Seatbelt blocks the gpg-agent socket for the
# session's own commands.
#
# Where macOS differs, because Seatbelt is a policy on Bash commands rather
# than a mount namespace around the whole process tree:
#   - Your own logins are kept out by settings.darwin.json instead of masks:
#     Read deny rules on ~/.config/configstore (the `firebase login` token)
#     and ~/.config/gcloud cover claude's file tools and sandboxed commands.
#   - There is no RAM-backed runtime dir, so the SA key goes to a private
#     directory under $TMPDIR, on disk (mktemp -d, key 0600). A watcher
#     removes it once claude exits; one left behind by a reboot is removed by
#     the next `cf` launch.
#   - firebase-tools reads its login from configstore and must write there
#     (MOTD and update-check caches). Instead of Linux's tmpfs over
#     ~/.config/configstore, it gets its own XDG_CONFIG_HOME: a symlink to
#     every ~/.config entry but configstore, a fresh empty directory added
#     with --add-dir so sandboxed commands can write it. Other tools that
#     read XDG_CONFIG_HOME see the same files as before.
#   - jira-cli is a Go program, and those fail TLS checks under Seatbelt, so
#     settings.darwin.json runs `jira` outside it (excludedCommands), like gh.
#   - Firebase's Google hosts are not in allowedDomains: the first call to
#     each asks for approval (in auto mode, claude names them on the command).
#
# Usage: claude-macos.bash claude [args...]
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: claude-macos.bash claude [args...]" >&2
  exit 2
fi

__cm_jira_pass="${JIRA_API_TOKEN_PASS:-claude/jira-token}"
__cm_jira_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/.jira/claude.yml"
if [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = "1" ]; then
  if ! command -v pass >/dev/null 2>&1; then
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_JIRA=1 but 'pass' is not on PATH; cannot read the token" >&2
  elif [ ! -f "$__cm_jira_cfg" ]; then
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_JIRA=1 but $__cm_jira_cfg is missing; create it from a plain terminal (see CLAUDE_SANDBOX_ALLOW_JIRA in claude-sandbox.bash). Not passing the token" >&2
  elif ! __cm_jira_tok=$(pass show "$__cm_jira_pass" 2>/dev/null) || [ -z "$__cm_jira_tok" ]; then
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_JIRA=1 but no token at 'pass show $__cm_jira_pass'; store claude's own API token there first (pass insert $__cm_jira_pass)" >&2
  else
    export JIRA_API_TOKEN="$__cm_jira_tok" JIRA_CONFIG_FILE="$__cm_jira_cfg"
    unset __cm_jira_tok
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_JIRA=1 — jira API token (pass: $__cm_jira_pass) exported as JIRA_API_TOKEN; readable by any code in this session" >&2
  fi
fi

__cm_fb_pass="${FIREBASE_SA_KEY_PASS:-claude/firebase-sa-key}"
__cm_tmp="${TMPDIR:-/tmp}"
__cm_tmp="${__cm_tmp%/}"
__cm_ws=""
if [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = "1" ]; then
  # Each workspace is named after the PID claude runs under (this shell's: see
  # the exec below). Remove those whose claude is gone but not their key, as
  # after a reboot.
  for d in "$__cm_tmp"/claude-macos.*; do
    [ -d "$d" ] || continue
    pid=${d##*/claude-macos.}
    pid=${pid%%.*}
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done
  if ! command -v pass >/dev/null 2>&1; then
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but 'pass' is not on PATH; cannot read the SA key" >&2
  elif ! __cm_fb_key=$(pass show "$__cm_fb_pass" 2>/dev/null) || [ -z "$__cm_fb_key" ]; then
    echo "claude-macos: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but no key at 'pass show $__cm_fb_pass'; store the scoped service-account JSON there first (pass insert -m $__cm_fb_pass)" >&2
  else
    case "$__cm_fb_key" in
      *'"private_key"'*'"client_email"'* | *'"client_email"'*'"private_key"'*)
        if __cm_ws=$(mktemp -d "$__cm_tmp/claude-macos.$$.XXXXXX") && __cm_ws=$(cd "$__cm_ws" && pwd -P); then
          trap 'rm -rf "$__cm_ws"' EXIT
          (
            umask 077
            printf '%s\n' "$__cm_fb_key" >"$__cm_ws/firebase-sa.json"
          )
          mkdir "$__cm_ws/config" "$__cm_ws/config/configstore"
          __cm_cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
          shopt -s dotglob nullglob
          for e in "$__cm_cfg"/*; do
            case "${e##*/}" in configstore) continue ;; esac
            ln -s "$e" "$__cm_ws/config/"
          done
          shopt -u dotglob nullglob
          export GOOGLE_APPLICATION_CREDENTIALS="$__cm_ws/firebase-sa.json"
          export XDG_CONFIG_HOME="$__cm_ws/config"
          # Higher-precedence credentials would outrank the SA key.
          unset FIREBASE_TOKEN GOOGLE_OAUTH_ACCESS_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN
          echo "claude-macos: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 — scoped firebase SA key (pass: $__cm_fb_pass) handed over as ADC; readable by any code in this session" >&2
        else
          __cm_ws=""
          echo "claude-macos: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but no private directory could be made under $__cm_tmp; not handing the SA key over" >&2
        fi
        ;;
      *)
        echo "claude-macos: CLAUDE_SANDBOX_ALLOW_FIREBASE=1 but 'pass show $__cm_fb_pass' is not a service-account key JSON (needs private_key + client_email); not handing it over" >&2
        ;;
    esac
    unset __cm_fb_key
  fi
fi

if [ -z "$__cm_ws" ]; then
  exec "$@"
fi
# claude must replace this shell, as bwrap does on Linux: tmux names the pane
# after the process group leader, and window autorename and the M-w/M-W
# save/restore flows key off "claude". An EXIT trap can't survive the exec,
# so a detached watcher waits for that PID to go, then removes the key.
trap - EXIT
(
  trap '' HUP INT TERM
  while kill -0 $$ 2>/dev/null; do sleep 15; done
  rm -rf "$__cm_ws"
) &
# --add-dir takes several paths, so it goes right after the program name,
# where claude.bash always puts an option next.
exec "$1" --add-dir "$__cm_ws/config/configstore" "${@:2}"
