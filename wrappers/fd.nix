{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = path: target:
    if useLink
    then pkgs.lib.mkLink "config/${path}" target
    else pkgs.lib.mkCopy "${configRoot}/${path}" target;
in

pkgs.symlinkJoin {
  name = "fd-with-config";
  paths = [ pkgs.fd ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "ignore" ".config/ignore"}

    wrapProgram $out/bin/fd \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
