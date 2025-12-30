{ pkgs, files }:

pkgs.symlinkJoin {
  name = "bash-with-config";
  paths = [ pkgs.bash ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "bash" ".config/bash"}
    ${files.sync "shell" ".config/shell"}
    ${files.sync "readline" ".config/readline"}
    ${files.sync "direnv" ".config/direnv"}

    wrapProgram $out/bin/bash \
      --add-flags "--rcfile $out/.config/bash/.bashrc" \
      --set NIX_OUT_SHELL "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
