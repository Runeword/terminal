{ pkgs }:

pkgs.buildGoModule {
  pname = "claude-statusline";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
