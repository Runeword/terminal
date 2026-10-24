{ pkgs }:

pkgs.buildGoModule {
  pname = "tmux-session-name";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
}
