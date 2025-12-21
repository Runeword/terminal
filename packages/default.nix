{ pkgs, configPath }:
import ./commons.nix { inherit pkgs; }
++ (
  if pkgs.stdenv.isDarwin then
    import ./darwin.nix { inherit pkgs; }
  else
    import ./linux.nix { inherit pkgs; }
)
