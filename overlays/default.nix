{ pkgs-24-05 }:
[
  (import ./channel-pins.nix { inherit pkgs-24-05; })
  (import ./tmux.nix)
  (import ./firebase-tools.nix)
]
