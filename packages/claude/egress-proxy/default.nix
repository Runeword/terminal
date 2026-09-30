{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-egress-proxy";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — no dependency vendoring required.
  vendorHash = null;
  ldflags = [
    "-s"
    "-w"
  ];
}
