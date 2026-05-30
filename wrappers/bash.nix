{
  pkgs,
  files,
  permeance,
  tests,
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
    passthru.tests.smoke = tests.smoke {
      name = "bash";
      description = "Verify bash wrapper sets NIX_OUT_SHELL correctly and the launcher resolves PERMEANCE_ROOT";
      script = ''
        nix_out=$(${self}/bin/bash -i -c 'echo $NIX_OUT_SHELL' 2>/dev/null)
        if [ "$nix_out" = "${self}" ]; then
          ok "NIX_OUT_SHELL points to wrapper"
        else
          fail "NIX_OUT_SHELL is '$nix_out', expected '${self}'"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/bash \
           && grep -qF '/.config/readline/inputrc' ${self}/bin/bash \
           && grep -qF '/.config/bash/.bashrc' ${self}/bin/bash; then
          ok "launcher resolves INPUTRC and --rcfile from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution"
        fi
      '';
    };
  };
in
self
