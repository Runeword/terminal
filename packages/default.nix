{ pkgs }:
import ./commons.nix { inherit pkgs; }
++ import ./custom.nix { inherit pkgs; }
++ (
  if pkgs.stdenv.isDarwin then
    import ./darwin.nix { inherit pkgs; }
  else
    import ./linux.nix { inherit pkgs; }
)
