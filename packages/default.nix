{ pkgs, system }:
import ./commons.nix { inherit pkgs; }
++ (
  if pkgs.stdenv.isDarwin then
    import ./darwin.nix { inherit pkgs system; }
  else
    import ./linux.nix { inherit pkgs system; }
)
