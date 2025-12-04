{ pkgs, mkConfig }:

pkgs.symlinkJoin {
  name = "zsh-with-config";
  paths = [
    pkgs.zsh
    pkgs.zsh-autosuggestions
  ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "zsh/zshrc" ".config/zsh/.zshrc"}
    ${mkConfig "shell" ".config/shell"}
    ${mkConfig "readline" ".config/readline"}
    ${mkConfig "direnv" ".config/direnv"}

    wrapProgram $out/bin/zsh \
      --set ZDOTDIR "$out/.config/zsh" \
      --set OUT "$out" \
      --set INPUTRC "$out/.config/readline/inputrc" \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
