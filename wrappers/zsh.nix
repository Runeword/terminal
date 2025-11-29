{ pkgs }:

pkgs.symlinkJoin {
  name = "zsh-with-config";
  paths = [
    pkgs.zsh
    pkgs.zsh-autosuggestions
  ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "zsh/zshrc" ".config/zsh/.zshrc"}
    ${pkgs.lib.mkLink "shell" ".config/shell"}
    ${pkgs.lib.mkLink "readline" ".config/readline"}
    ${pkgs.lib.mkLink "direnv" ".config/direnv"}

    wrapProgram $out/bin/zsh \
      --set ZDOTDIR "$out/.config/zsh" \
      --set OUT "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
