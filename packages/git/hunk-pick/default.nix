{ pkgs }:

pkgs.buildGoModule {
  pname = "git-hunk-pick";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
}
