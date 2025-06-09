{
  pkgs,
  extraPackages,
  extraFonts,
}:
let
  common = import ./common.nix { inherit pkgs; };
in
common.mkProgramWrapper {
  name = "bat";
  program = pkgs.bat;
  configPath = ".config/bat";
  inherit extraPackages extraFonts;
} 