{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = path: target:
    if useLink
    then pkgs.lib.mkLink "config/${path}" target
    else pkgs.lib.mkCopy "${configRoot}/${path}" target;
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
