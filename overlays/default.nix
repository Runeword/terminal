{ configPath, pkgs-24-05 }:
[
  (import ./lib.nix { inherit configPath; })
  (final: prev: { awscli2 = pkgs-24-05.awscli2; })
]
