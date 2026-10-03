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
      description = "Verify zsh wrapper exec's the real binary, the leader table renders, god/godc name and clear Go dev builds, bundled mode provisions the claude profile with its sandbox overlay, failing closed, the claude connection picker launches what was picked, and __open_recent offers nvim's recent files newest first";
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

        # Bundled mode: this bundle has no .claude, so a claude profile comes from
        # the claude wrapper's, with this OS's sandbox overlay merged in; an overlay
        # that does not merge refuses the launch instead.
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        provision='. ${self}/.config/shell/functions/claude.bash; __claude_instance=1; __claude_provision_config'
        if PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$provision" \
          && [ "$(${pkgs.jq}/bin/jq -c .sandbox "$HOME/.claude-1/settings.json")" \
            = "$(${pkgs.jq}/bin/jq -c .sandbox ${claude}/.claude/settings.$os.json)" ]; then
          ok "bundled mode provisions the claude profile with the $os sandbox overlay"
        else
          fail "bundled mode does not provision the claude profile with its sandbox overlay"
        fi
        mkdir -p "$TMPDIR/tree/.claude"
        echo '{}' > "$TMPDIR/tree/.claude/settings.json"
        echo 'not json' > "$TMPDIR/tree/.claude/settings.$os.json"
        if PATH=${pkgs.jq}/bin:$PATH PERMEANCE_ROOT=$TMPDIR/tree ${self}/bin/zsh -f -c "$provision" 2> /dev/null; then
          fail "a sandbox overlay that does not merge still provisions the claude profile"
        else
          ok "a sandbox overlay that does not merge refuses the launch"
        fi

        # The connection picker (leader cc) launches a plain session plus what
        # was picked: a credential as the launcher's opt-in flag, an MCP plugin
        # on top of the default ones. A stand-in fzf picks jira and figma-mcp.
        connect='. ${self}/.config/shell/functions/claude.bash
          fzf() { printf "jira\nfigma-mcp\n"; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_connect'
        case "$(CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$connect")" in
          "CLAUDE_SANDBOX_ALLOW_JIRA=1 "*/nix-lsp\ *--plugin-dir\ */figma-mcp\ *)
            ok "the connection picker launches jira and figma-mcp on top of the default plugins"
            ;;
          *) fail "the connection picker does not launch what was picked" ;;
        esac

        # __open_recent offers nvim's oldfiles newest first, read from the
        # viminfofile the nvim config keeps under $XDG_CACHE_HOME: a stand-in
        # nvim answers for that file only, a stand-in fzf picks the first line.
        touch "$HOME/a" "$HOME/b"
        recent='. ${self}/.config/shell/functions/fm.sh
          nvim() {
            if [ "$1 $2 $3" = "-es -i $XDG_CACHE_HOME/nvim/viminfo" ]; then
              printf "1: %s\n2: %s\n" "$HOME/b" "$HOME/a" > "''${4#+redir! > }"
            else
              printf "%s\n" "$*"
            fi
          }
          fzf() { head -n 1; }
          __open_recent'
        if [ "$(XDG_CACHE_HOME=$HOME/cache ${self}/bin/zsh -f -c "$recent")" = "$HOME/b" ]; then
          ok "__open_recent offers nvim's recent files newest first"
        else
          fail "__open_recent does not offer nvim's recent files newest first"
        fi
      '';
    };
  };
in
self
