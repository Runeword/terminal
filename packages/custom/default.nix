{ pkgs }:

[
  (pkgs.buildGoModule {
    pname = "git-branches";
    version = "0.1.0";
    src = ./git-branches;
    vendorHash = null;
  })
  (import ./firefox-mcp.nix { inherit pkgs; })
]
