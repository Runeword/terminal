#!/bin/sh

# Thin Figma REST wrapper. Talks to https://api.figma.com/v1 with a personal
# access token pulled from pass at call time — never persisted to env/disk, and
# fed to curl on stdin so it never lands in argv (/proc/<pid>/cmdline).
#
#   pass insert FIGMA_TOKEN        # one-time; override the entry via FIGMA_TOKEN_PASS
#   figma /me | jq .               # auth check
#   figma "/files/$(fkey URL)?depth=2" | jq .
#   figma "/files/$(fkey URL)/nodes?ids=1:2" | jq .
#   figma "/images/$(fkey URL)?ids=1:2&format=svg" | jq -r '.images[]'
#
# Docs: https://developers.figma.com/docs/rest-api/
# Node ids: Figma URLs write 1-2, the API wants 1:2. file/nodes/images are
# Tier-1 endpoints, rate-limited by seat — use ?depth= to keep payloads small.

# figma <api-path+query> — GET the v1 API with the pass token; pipe JSON to jq.
figma() {
  [ -z "${1:-}" ] && {
    echo "usage: figma <api-path> | fkey <url>   e.g.  figma /me | jq ." >&2
    return 2
  }
  local t
  t="$(pass show "${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}" 2>/dev/null)" || {
    echo "figma: no token in pass (${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}); add:  pass insert ${FIGMA_TOKEN_PASS:-FIGMA_TOKEN}" >&2
    return 1
  }
  printf 'X-Figma-Token: %s\n' "$t" | curl -fsS -H @- "https://api.figma.com/v1$1"
}

# fkey <url|key> — extract the file key from a Figma URL, else echo a bare key.
fkey() {
  case "${1:-}" in
  http*) printf '%s\n' "$1" |
    sed -nE 's#.*/(file|design|board|proto|slides)/([A-Za-z0-9_-]+).*#\2#p' ;;
  *) printf '%s\n' "$1" ;;
  esac
}
