{
  pkgs,
  files,
  permeance,
  claude,
}:

let
  # The leader-key picker (.config/shell/functions/aliases.sh) renders the
  # bundled .config/shell/leader.toml through this binary; the smoke test
  # exercises that path against the wrapper's own copy of the table.
  leaderAliases = import ../packages/custom/leader-aliases { inherit pkgs; };
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
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "zsh";
      description = "Verify zsh wrapper exec's the real binary and the bundled leader table renders";
      script = ''
        if ${self}/bin/zsh --version > /dev/null 2>&1; then
          ok "wrapper execs real zsh"
        else
          fail "wrapper does not exec real zsh"
        fi

        # A leader.toml that fails to render leaves every chord dead, so check
        # the fields the widget reads (raw command, mode) for a known chord.
        sep=$(printf '\302\240')
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.toml \
          | awk -F "$sep" '$1 ~ /^gt +$/ && $5 == "git status" && $6 == "run" { found = 1 } END { exit !found }'; then
          ok "bundled leader.toml renders and binds gt to git status"
        else
          fail "bundled leader.toml does not render the gt chord"
        fi
      '';
    };
  };
in
self
