#!/usr/bin/env bash
# Checks, on a GitHub macOS runner, what the claude setup relies on on a Mac,
# which nothing else here can: Claude Code's built-in sandbox there is
# sandbox-runtime (srt) applying Seatbelt to Bash commands, Seatbelt can't run
# inside a Nix build, and there is no Mac at hand. So this drives srt itself,
# with sources/.claude/settings.darwin.json turned into srt settings the way
# Claude Code applies them: Read deny rules become filesystem.denyRead,
# sandbox.network and sandbox.filesystem the same keys, and the cwd plus the
# configstore claude-macos.bash passes with --add-dir filesystem.allowWrite.
# claude-macos.bash itself, from the claude-sandbox revision flake.lock pins,
# runs under Apple's /bin/bash 3.2 and BSD tools, with stand-ins for pass and
# claude.
#
# Everything happens under a throwaway $HOME, so nothing lands in a real one.
# The tools come from the nixpkgs pinned in flake.lock (read with the runner's
# jq), not from the flake, so permeance is never fetched; claude-sandbox,
# private too, comes through the access token ci.yml sets up for nix. Run by
# ci.yml on its macOS machine, after the flake check.
set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd -P)
w=$(mktemp -d)
w=$(cd "$w" && pwd -P)
trap 'rm -rf "$w"' EXIT

nixpkgs=$(jq -r '.nodes.nixpkgs.locked | "github:\(.owner)/\(.repo)/\(.rev)"' "$repo/flake.lock")
sandbox=$(jq -r '.nodes[.nodes.root.inputs["claude-sandbox"]].locked | "github:\(.owner)/\(.repo)/\(.rev)"' "$repo/flake.lock")
sandbox_src=$(nix flake prefetch --json "$sandbox" | jq -r .storePath)
for p in sandbox-runtime ripgrep go; do
  PATH="$(nix build --no-link --print-out-paths "$nixpkgs#$p" | head -1)/bin:$PATH"
done
export PATH
echo "macOS $(sw_vers -productVersion), $(/bin/bash --version | head -1)"
echo "srt: $(command -v srt)"

export HOME="$w/home"
mkdir -p "$HOME/.config/configstore" "$HOME/.config/gcloud" "$HOME/.config/.jira" \
  "$HOME/.config/claude-check" "$HOME/.cache/nix" "$HOME/.local/state/nix" "$HOME/.cache/direnv"
echo '{"user": "personal"}' >"$HOME/.config/configstore/firebase-tools.json"
echo secret >"$HOME/.config/gcloud/credentials.db"
echo readable >"$HOME/.config/claude-check/control"
: >"$HOME/.config/.jira/claude.yml"

failures=0
ok() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# claude-macos.bash for `cj` + `cf`. The stand-in claude records what it was
# handed, then waits, so its workspace can be checked under Seatbelt while
# "claude" runs.
mac="$w/mac"
mkdir -p "$mac/bin" "$mac/out"
cat >"$mac/bin/pass" <<'EOF'
#!/bin/sh
case "$*" in
  "show claude/jira-token") echo fake-jira-token ;;
  "show claude/firebase-sa-key") echo '{"private_key": "fake-sa-key", "client_email": "sa@fake"}' ;;
  *) exit 1 ;;
esac
EOF
cat >"$mac/bin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$CLAUDE_OUT/argv"
env >"$CLAUDE_OUT/env"
cat "$GOOGLE_APPLICATION_CREDENTIALS" >"$CLAUDE_OUT/key" 2>/dev/null
ls -A "${XDG_CONFIG_HOME:-$HOME/.config}/configstore" >"$CLAUDE_OUT/configstore" 2>/dev/null
: >"$CLAUDE_OUT/ready"
while [ ! -e "$CLAUDE_OUT/done" ]; do sleep 0.2; done
EOF
chmod +x "$mac/bin/pass" "$mac/bin/claude"
PATH="$mac/bin:$PATH" TMPDIR="$mac" CLAUDE_OUT="$mac/out" \
  CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_ALLOW_FIREBASE=1 \
  /bin/bash "$sandbox_src/launchers/claude-macos.bash" claude --version \
  >"$mac/stdout" 2>"$mac/err" &
session=$!
for _ in $(seq 100); do
  [ -e "$mac/out/ready" ] && break
  sleep 0.1
done
key=$(sed -n 's/^GOOGLE_APPLICATION_CREDENTIALS=//p' "$mac/out/env" 2>/dev/null || true)
store=$(sed -n 2p "$mac/out/argv" 2>/dev/null || true)
if grep -qx 'JIRA_API_TOKEN=fake-jira-token' "$mac/out/env" &&
  grep -q fake-sa-key "$mac/out/key" &&
  [ "$(head -1 "$mac/out/argv")" = --add-dir ] &&
  [ -f "$mac/out/configstore" ] && [ ! -s "$mac/out/configstore" ]; then
  ok "claude-macos.bash under /bin/bash hands claude the jira token and SA key, not the firebase login"
else
  fail "claude-macos.bash under /bin/bash did not hand over the credentials: $(cat "$mac/err")"
fi

# srt settings from settings.darwin.json, plus what claude-macos.bash's
# --add-dir grants.
jq --arg store "$store" '{
  network: {
    allowedDomains: .sandbox.network.allowedDomains,
    deniedDomains: [],
    allowUnixSockets: .sandbox.network.allowUnixSockets,
    strictAllowlist: true
  },
  filesystem: {
    denyRead: [.permissions.deny[] | select(startswith("Read("))
      | ltrimstr("Read(") | rtrimstr(")") | rtrimstr("/**")],
    allowWrite: (.sandbox.filesystem.allowWrite + ["."]
      + (if $store == "" then [] else [$store] end)),
    denyWrite: []
  }
}' "$repo/sources/.claude/settings.darwin.json" >"$w/srt.json"

# check WHAT allow|deny COMMAND: runs COMMAND under Seatbelt with those settings.
check() {
  local got
  if srt --settings "$w/srt.json" -c "$3" >"$w/out" 2>&1; then got=allow; else got=deny; fi
  if [ "$got" = "$2" ]; then
    ok "$1"
  else
    fail "$1 (wanted $2, got $got)"
    sed 's/^/    /' "$w/out"
  fi
}

check "the firebase login in ~/.config/configstore is unreadable" deny \
  "cat ~/.config/configstore/firebase-tools.json"
check "the gcloud credentials are unreadable" deny "cat ~/.config/gcloud/credentials.db"
check "the rest of ~/.config stays readable" allow "cat ~/.config/claude-check/control"
check "the real configstore is not writable" deny "echo x >~/.config/configstore/probe"
if [ -n "$store" ]; then
  check "firebase can write the configstore claude-macos.bash added" allow "echo x >'$store/probe'"
  check "the SA key is readable in the session" allow "cat '$key'"
  check "the SA key is not writable in the session" deny "echo x >>'$key'"
fi
check "the nix daemon is reachable (allowUnixSockets)" allow "nix store info"
python3 -c "import socket, time
s = socket.socket(socket.AF_UNIX); s.bind('$w/agent.sock'); s.listen(1); time.sleep(600)" &
listener=$!
for _ in $(seq 50); do
  [ -S "$w/agent.sock" ] && break
  sleep 0.1
done
check "any other unix socket (gpg-agent's, say) is refused" deny \
  "python3 -c \"import socket; socket.socket(socket.AF_UNIX).connect('$w/agent.sock')\""
kill "$listener" 2>/dev/null || true
check "a listed host is reachable" allow \
  "curl -sS --retry 3 --retry-all-errors --max-time 30 -o /dev/null https://github.com"
check "an unlisted host is refused" deny "curl -sS --max-time 30 -o /dev/null https://example.com"

# Why settings.darwin.json runs `jira` outside Seatbelt: Go programs verify
# TLS through the system trust service, which Seatbelt blocks. Reported, not
# checked: if this starts working, the exclusion can go.
cat >"$w/gotls.go" <<'EOF'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	resp, err := http.Get(os.Args[1])
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	_ = resp.Body.Close()
	fmt.Println(resp.Status)
}
EOF
(cd "$w" && GOCACHE="$w/gocache" GOPATH="$w/gopath" go build -o gotls gotls.go)
if srt --settings "$w/srt.json" -c "$w/gotls https://github.com" >"$w/out" 2>&1; then
  echo "note: Go verifies TLS under Seatbelt ($(tail -1 "$w/out")): jira could run inside it"
else
  echo "note: Go fails TLS under Seatbelt ($(tail -1 "$w/out")): jira stays in excludedCommands"
fi

# Let "claude" exit: claude-macos.bash's watcher then removes the workspace,
# SA key included, within its 15-second poll.
: >"$mac/out/done"
wait "$session" || true
for _ in $(seq 40); do
  [ -n "$key" ] && [ -e "$key" ] || break
  sleep 0.5
done
if [ -n "$key" ] && [ ! -e "$key" ]; then
  ok "the SA key is gone once claude exits"
else
  fail "the SA key is still on disk after claude exited: ${key:-none}"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
