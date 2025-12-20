{ configPath, defaultConfigRoot, pkgs-24-05 }:
[
  (import ./lib.nix { inherit configPath defaultConfigRoot; })
  (final: prev: { awscli2 = pkgs-24-05.awscli2; })
]
