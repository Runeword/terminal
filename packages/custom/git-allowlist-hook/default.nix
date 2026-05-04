{ pkgs }:

pkgs.buildGoModule {
  pname = "git-allowlist-hook";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-AI5r/s5q8nX2tw5r3hnuQd/NYsijOJ0pM0JHcytkVdc=";
}
