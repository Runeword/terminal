{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = pkgs.lib.mkConfig useLink configRoot;
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
