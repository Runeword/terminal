{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = pkgs.lib.mkConfig useLink configRoot;
in

pkgs.symlinkJoin {
  name = "starship-with-config";
  paths = [ pkgs.starship ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "starship.toml" ".config/starship.toml"}

    wrapProgram $out/bin/starship \
      --set STARSHIP_CONFIG "$out/.config/starship.toml"
  '';
}
