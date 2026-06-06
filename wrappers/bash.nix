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
        NIX_OUT_SHELL = "@OUT@";
      };
      flags = [
        "--rcfile"
        "$PERMEANCE_ROOT/.config/bash/.bashrc"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "bash";
      description = "Verify bash wrapper exec's the real binary";
      script = ''
        if ${self}/bin/bash --version > /dev/null 2>&1; then
          ok "wrapper execs real bash"
        else
          fail "wrapper does not exec real bash"
        fi
      '';
    };
  };
in
self
