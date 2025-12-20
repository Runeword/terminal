{ configRoot, useLink, pkgs-24-05 }:
[
  (import ./lib.nix { inherit configRoot useLink; })
  (final: prev: { awscli2 = pkgs-24-05.awscli2; })
]
