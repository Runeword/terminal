{ pkgs }:

pkgs.buildGoModule {
  pname = "fm-query";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
}
