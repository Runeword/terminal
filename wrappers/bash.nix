{ pkgs, useLink ? false, configRoot ? ../config }:

let
  mkConfig = path: target:
    if useLink
    then pkgs.lib.mkLink "config/${path}" target
    else pkgs.lib.mkCopy "${configRoot}/${path}" target;
in

pkgs.symlinkJoin {
  name = "bash-with-config";
  paths = [ pkgs.bash ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "bash/bashrc" ".config/bash/.bashrc"}
    ${mkConfig "shell" ".config/shell"}
    ${mkConfig "readline" ".config/readline"}
    ${mkConfig "direnv" ".config/direnv"}

    wrapProgram $out/bin/bash \
      --add-flags "--rcfile $out/.config/bash/.bashrc" \
      --set OUT "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
