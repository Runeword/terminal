{ pkgs, lefthook }:
lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
  hooks = import ./lefthook-hooks.nix;
}
