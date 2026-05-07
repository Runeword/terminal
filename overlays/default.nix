{ pkgs-24-05, pkgs-25-11 }:
[
  (import ./channel-pins.nix { inherit pkgs-24-05 pkgs-25-11; })
  (import ./firebase-tools.nix)
]
