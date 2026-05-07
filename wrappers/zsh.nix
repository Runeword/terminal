{
  pkgs,
  files,
  tests,
  claude,
}:

let
  config = files.mkConfig "zsh-config" [
    {
      source = "zsh";
      target = ".config/zsh";
    }
    {
      source = "shell";
      target = ".config/shell";
    }
    {
      source = "readline";
      target = ".config/readline";
    }
    {
      source = "direnv";
      target = ".config/direnv";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "zsh-with-config";
    paths = [
      pkgs.zsh
      pkgs.zsh-autosuggestions
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      mkdir -p $out/paths
      ln -s ${claude} $out/paths/claude

      wrapProgram $out/bin/zsh \
        --add-flags --no-global-rcs \
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

        # Sourcing .zshrc must not produce errors. -i would load /etc/zshrc from the host without --no-global-rcs (set above).
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
