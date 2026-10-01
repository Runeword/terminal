{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-sessions";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
