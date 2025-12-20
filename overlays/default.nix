{ configPath, pkgs-24-05 }:
let
  useLink = configPath != null;
  configRoot = if configPath != null then configPath else toString ../config;
in
[
  (import ./lib.nix { inherit configRoot useLink; })
  (final: prev: { awscli2 = pkgs-24-05.awscli2; })
]
