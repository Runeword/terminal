{ pkgs }:

pkgs.symlinkJoin {
  name = "bash-with-config";
  paths = [ pkgs.bash ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "bash/bashrc" ".config/bash/.bashrc"}
    ${pkgs.lib.mkLink "shell" ".config/shell"}
    ${pkgs.lib.mkLink "readline" ".config/readline"}
    ${pkgs.lib.mkLink "direnv" ".config/direnv"}

    wrapProgram $out/bin/bash \
      --add-flags "--rcfile $out/.config/bash/.bashrc" \
      --set OUT "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
