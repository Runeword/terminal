{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = pkgs.lib.mkConfig useLink configRoot;
in

pkgs.symlinkJoin {
  name = "delta-with-config";
  paths = [ pkgs.delta ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "delta/config" ".config/delta/config"}

    wrapProgram $out/bin/delta \
      --add-flags "--config $out/.config/delta/config"
  '';
}
