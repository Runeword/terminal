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
  leaderAliases = import ../packages/leader-aliases { inherit pkgs; };
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
      description = "Verify zsh wrapper exec's the real binary, the leader table renders, and god/godc name and clear Go dev builds";
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

        # godc (and gow when it stops) clears the Go dev builds that shadow the
        # Nix copies: every compiled binary in .direnv/bin, not nix-direnv's script.
        bin=$HOME/terminal/.direnv/bin
        mkdir -p "$bin"
        printf '\177ELF' > "$bin/stale"
        printf '#!/bin/sh\n' > "$bin/nix-direnv-reload"
        ${self}/bin/zsh -f -c '. ${self}/.config/shell/functions/go.bash; __go_dev clean' > /dev/null
        if [ ! -e "$bin/stale" ] && [ -e "$bin/nix-direnv-reload" ]; then
          ok "godc clears compiled dev builds and keeps nix-direnv-reload"
        else
          fail "godc does not clear exactly the compiled dev builds"
        fi

        # god names each dev build after its go.mod module, not its directory
        # (packages/git/branches builds git-branches); a stub go records it.
        mkdir -p "$HOME/terminal/packages/grp/tool" "$HOME/stub"
        printf 'module grp-tool\n' > "$HOME/terminal/packages/grp/tool/go.mod"
        printf '#!/bin/sh\n: > "$3"\n' > "$HOME/stub/go"
        chmod +x "$HOME/stub/go"
        PATH=$HOME/stub:$PATH ${self}/bin/zsh -f -c '. ${self}/.config/shell/functions/go.bash; __go_dev' > /dev/null
        if [ -e "$bin/grp-tool" ] && [ ! -e "$bin/tool" ]; then
          ok "god names dev builds after their go.mod module"
        else
          fail "god does not name dev builds after their go.mod module"
        fi
      '';
    };
  };
in
self
