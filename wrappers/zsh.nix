{
  pkgs,
  files,
  tests,
}:

let
  self = pkgs.symlinkJoin {
    name = "zsh-with-config";
    paths = [
      pkgs.zsh
      pkgs.zsh-autosuggestions
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      ${files.sync "zsh" ".config/zsh"}
      ${files.sync "shell" ".config/shell"}
      ${files.sync "readline" ".config/readline"}
      ${files.sync "direnv" ".config/direnv"}

      wrapProgram $out/bin/zsh \
        --set ZDOTDIR "$out/.config/zsh" \
        --set NIX_OUT_SHELL "$out" \
        --set INPUTRC "$out/.config/readline/inputrc" \
        --set DIRENV_CONFIG "$out/.config/direnv"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "zsh";
      description = "Verify zsh wrapper loads its config without errors";
      script = ''
        zdotdir=$(${self}/bin/zsh -c 'echo $ZDOTDIR')
        if [ "$zdotdir" = "${self}/.config/zsh" ]; then
          ok "ZDOTDIR points to wrapper config"
        else
          fail "ZDOTDIR is '$zdotdir', expected '${self}/.config/zsh'"
        fi

        # Sourcing .zshrc must not produce errors.
        err=$(${self}/bin/zsh -i -c 'exit 0' 2>&1 >/dev/null)
        if [ -z "$err" ]; then
          ok ".zshrc sources without errors"
        else
          fail ".zshrc produced errors:"
          echo "$err" | sed 's/^/    /'
        fi
      '';
    };
  };
in
self
