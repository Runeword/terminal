{
  pkgs,
  files,
  permeance,
  tests,
  claude,
}:

let
  config = files.mkConfig "zsh-config" [
    ".config/zsh"
    ".config/shell"
    ".config/readline"
    ".config/direnv"
  ];
  self = pkgs.symlinkJoin {
    name = "zsh-with-config";
    paths = [
      pkgs.zsh
      pkgs.zsh-autosuggestions
      config
    ];
    postBuild = ''
      mkdir -p $out/paths
      ln -s ${claude} $out/paths/claude

      ${permeance.installLauncher {
        binName = "zsh";
        configEnv = {
          ZDOTDIR = ".config/zsh";
          INPUTRC = ".config/readline/inputrc";
          DIRENV_CONFIG = ".config/direnv";
        };
        staticEnv = {
          NIX_OUT_SHELL = "@OUT@";
        };
        flags = [ "--no-global-rcs" ];
      }}
    '';
    passthru.tests.smoke = tests.smoke {
      name = "zsh";
      description = "Verify zsh wrapper resolves config bundled and via PERMEANCE_ROOT";
      script = ''
        # Bundled: PERMEANCE_ROOT unset → ZDOTDIR points at $out.
        zdotdir=$(${self}/bin/zsh -c 'echo $ZDOTDIR')
        if [ "$zdotdir" = "${self}/.config/zsh" ]; then
          ok "ZDOTDIR points to bundled wrapper config"
        else
          fail "ZDOTDIR is '$zdotdir', expected '${self}/.config/zsh'"
        fi

        # Permeance: PERMEANCE_ROOT set → ZDOTDIR redirects to that root.
        fake_root=$(mktemp -d)
        zdotdir_p=$(PERMEANCE_ROOT="$fake_root" ${self}/bin/zsh --no-rcs -c 'echo $ZDOTDIR')
        if [ "$zdotdir_p" = "$fake_root/.config/zsh" ]; then
          ok "PERMEANCE_ROOT redirects ZDOTDIR"
        else
          fail "ZDOTDIR with PERMEANCE_ROOT is '$zdotdir_p', expected '$fake_root/.config/zsh'"
        fi

        # Sourcing .zshrc must not produce errors. -i would load /etc/zshrc from the host without --no-global-rcs (set in the launcher).
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
