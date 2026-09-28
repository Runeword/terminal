{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-session-status";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
