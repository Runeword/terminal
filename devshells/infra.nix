{ pkgs }:
let
  helpers = [
    {
      name = "infra";
      usage = "infra <args>";
      doc = "OpenTofu against ./infra (auth via pass GH_TOKEN)";
      text = ''
        # Wrap `tofu` so it always runs against ./infra and authenticates with a
        # GitHub token resolved at runtime: the pass entry GH_TOKEN (where the
        # token now lives), falling back to `gh auth token` for a plain gh login.
        set -euo pipefail
        if ! root="$(git rev-parse --show-toplevel 2>/dev/null)" || [ ! -d "$root/infra" ]; then
          echo "infra: must be run from inside the terminal repo (no ./infra found)" >&2
          exit 1
        fi
        cd "$root/infra"
        if [ -z "''${GITHUB_TOKEN:-}" ]; then
          GITHUB_TOKEN="$(${pkgs.pass}/bin/pass show GH_TOKEN 2>/dev/null)" \
            || GITHUB_TOKEN="$(${pkgs.gh}/bin/gh auth token 2>/dev/null)" \
            || true
          if [ -z "$GITHUB_TOKEN" ]; then
            echo "infra: no GITHUB_TOKEN — run \`pass insert GH_TOKEN\` (a PAT with repo scope) or export GITHUB_TOKEN" >&2
            exit 1
          fi
        fi
        # Hand the token to tofu (and the git/provider subprocesses it spawns,
        # which also need it) via its environment. Using `exec env …` means the
        # interactive devshell is never touched — this launcher process is
        # replaced by tofu.
        exec ${pkgs.coreutils}/bin/env GITHUB_TOKEN="$GITHUB_TOKEN" ${pkgs.opentofu}/bin/tofu "$@"
      '';
    }
  ];
in
pkgs.mkShell {
  packages = [ pkgs.opentofu ] ++ map (h: pkgs.writeShellScriptBin h.name h.text) helpers;
  passthru.helpers = helpers;
}
