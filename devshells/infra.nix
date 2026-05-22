{ pkgs }:
pkgs.mkShell {
  packages = [
    pkgs.opentofu
    (pkgs.writeShellScriptBin "infra" ''
      # Wrap `tofu` so it always runs against ./infra and authenticates with
      # the user's existing gh credentials instead of a separate PAT.
      set -euo pipefail
      if ! root="$(git rev-parse --show-toplevel 2>/dev/null)" || [ ! -d "$root/infra" ]; then
        echo "infra: must be run from inside the terminal repo (no ./infra found)" >&2
        exit 1
      fi
      cd "$root/infra"
      if [ -z "''${GITHUB_TOKEN:-}" ]; then
        if ! GITHUB_TOKEN="$(${pkgs.gh}/bin/gh auth token 2>/dev/null)"; then
          echo "infra: no GITHUB_TOKEN set and \`gh auth token\` failed" >&2
          echo "infra: run \`gh auth login\` (token needs scopes: repo, administration:write) or export GITHUB_TOKEN" >&2
          exit 1
        fi
      fi
      # Pass the token via `env` rather than `export` so it stays scoped to
      # tofu's process and isn't picked up by anything tofu shells out to.
      exec ${pkgs.coreutils}/bin/env GITHUB_TOKEN="$GITHUB_TOKEN" ${pkgs.opentofu}/bin/tofu "$@"
    '')
  ];
}
