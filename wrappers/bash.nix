{
  pkgs,
  files,
  permeance,
}:

let
  config = files.mkConfig "bash-config" [
    ".config/bash"
    ".config/shell"
    ".config/readline"
    ".config/direnv"
  ];
  self = pkgs.symlinkJoin {
    name = "bash-with-config";
    paths = [
      pkgs.bash
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "bash";
      configEnv = {
        INPUTRC = ".config/readline/inputrc";
        DIRENV_CONFIG = ".config/direnv";
      };
      staticEnv = {
        NIX_OUT_SHELL = permeance.out;
      };
      flags = [
        "--rcfile"
        "${permeance.root}/.config/bash/.bashrc"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "bash";
      description = "Verify bash wrapper exec's the real binary, and the bundled .bashrc sets HISTFILE without exporting it";
      script = ''
        if ${self}/bin/bash --version > /dev/null 2>&1; then
          ok "wrapper execs real bash"
        else
          fail "wrapper does not exec real bash"
        fi

        # The bundled .bashrc sets HISTFILE without exporting it: a child bash
        # that does not read it (nix develop's) would inherit it and cut the
        # history to 500 lines. bash -i warns about job control without a tty.
        case "$(${self}/bin/bash -i -c 'printf "%s|" "$HISTFILE"; printenv HISTFILE' 2>/dev/null)" in
          */bash/history"|") ok "the bundled .bashrc sets HISTFILE without exporting it" ;;
          *) fail "the bundled .bashrc exports HISTFILE, or does not set it" ;;
        esac
      '';
    };
  };
in
self
