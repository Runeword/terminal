{ pkgs }:

pkgs.symlinkJoin {
  name = "zsh-with-config";
  paths = [
    pkgs.zsh
    pkgs.zsh-autosuggestions
  ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "zsh/zshrc" ".config/zsh/.zshrc"}
    ${pkgs.lib.mkConfig "shell" ".config/shell"}
    ${pkgs.lib.mkConfig "readline" ".config/readline"}
    ${pkgs.lib.mkConfig "direnv" ".config/direnv"}

    wrapProgram $out/bin/zsh \
      --set ZDOTDIR "$out/.config/zsh" \
      --set NIX_OUT_SHELL "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
