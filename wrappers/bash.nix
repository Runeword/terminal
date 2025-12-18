{ pkgs }:

pkgs.symlinkJoin {
  name = "bash-with-config";
  paths = [ pkgs.bash ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "bash/bashrc" ".config/bash/.bashrc"}
    ${pkgs.lib.mkConfig "shell" ".config/shell"}
    ${pkgs.lib.mkConfig "readline" ".config/readline"}
    ${pkgs.lib.mkConfig "direnv" ".config/direnv"}

    wrapProgram $out/bin/bash \
      --add-flags "--rcfile $out/.config/bash/.bashrc" \
      --set NIX_OUT_SHELL "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
