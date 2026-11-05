{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-shell-guard";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
}
