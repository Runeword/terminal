{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = path: target:
    if useLink
    then pkgs.lib.mkLink "config/${path}" target
    else pkgs.lib.mkCopy "${configRoot}/${path}" target;
in

pkgs.symlinkJoin {
  name = "ripgrep-with-config";
  paths = [ pkgs.ripgrep ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "ignore" ".config/ignore"}
    ${mkConfig "ripgrep/ripgreprc" ".config/ripgrep/ripgreprc"}

    wrapProgram $out/bin/rg \
      --set RIPGREP_CONFIG_PATH "$out/.config/ripgrep/ripgreprc" \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
