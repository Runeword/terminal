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
          NIX_OUT_SHELL = permeance.out;
        };
        flags = [ "--no-global-rcs" ];
      }}
    '';
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "zsh";
      description = "Verify zsh wrapper exec's the real binary, the leader table renders, god/godc name and clear Go dev builds, bundled mode provisions the claude profile with its sandbox overlay, failing closed, the claude connection picker launches what was picked, a launch drops what a session planted for the next one, the untracked-file preview and __open_file pass paths after --, and __open_recent offers nvim's recent files newest first";
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
        # PERMEANCE_STRICT=0: the launcher's strict check would refuse this tree,
        # which has no .config, before zsh ran; the message pins the refusal on
        # the merge.
        mkdir -p "$TMPDIR/tree/.claude"
        echo '{}' > "$TMPDIR/tree/.claude/settings.json"
        echo 'not json' > "$TMPDIR/tree/.claude/settings.$os.json"
        if refusal=$(PATH=${pkgs.jq}/bin:$PATH PERMEANCE_ROOT=$TMPDIR/tree PERMEANCE_STRICT=0 ${self}/bin/zsh -f -c "$provision" 2>&1); then
          fail "a sandbox overlay that does not merge still provisions the claude profile"
        else
          case "$refusal" in
            *"could not merge"*) ok "a sandbox overlay that does not merge refuses the launch" ;;
            *) fail "the claude profile was refused before the overlay merge: $refusal" ;;
          esac
        fi

        # The connection picker (leader cc) launches a plain session plus what
        # was picked: a credential as the launcher's opt-in flag, an MCP plugin
        # on top of the default ones. A stand-in fzf picks jira, figma-mcp and
        # google-workspace-mcp, whose token store needs the launcher's opt-in.
        connect='. ${self}/.config/shell/functions/claude.bash
          fzf() { printf "jira\nfigma-mcp\ngoogle-workspace-mcp\n"; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_connect'
        case "$(CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$connect")" in
          "CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_ALLOW_GOOGLE_WORKSPACE=1 "*/nix-lsp\ *--plugin-dir\ */figma-mcp\ *--plugin-dir\ */google-workspace-mcp\ *)
            ok "the connection picker launches jira, figma-mcp and google-workspace-mcp on top of the default plugins"
            ;;
          *) fail "the connection picker does not launch what was picked" ;;
        esac

        # A launch drops what a session can leave for the next one to run: MCP
        # servers in the profile's .claude.json, and the local settings claude
        # does not write itself (hooks here), keeping its permission rules.
        mkdir -p "$HOME/proj/.claude"
        echo '{"mcpServers":{"a":{}},"projects":{"/p":{"mcpServers":{"b":{}}}}}' > "$HOME/.claude-1/.claude.json"
        echo '{"hooks":{},"permissions":{"allow":["Bash(ls)"],"defaultMode":"bypassPermissions"}}' > "$HOME/proj/.claude/settings.local.json"
        launch='. ${self}/.config/shell/functions/claude.bash
          __claude_run() { :; }
          __claude'
        (cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$launch" 2>/dev/null)
        if [ "$(${pkgs.jq}/bin/jq -c '[.mcpServers, .projects."/p".mcpServers]' "$HOME/.claude-1/.claude.json")" = '[{},{}]' ] \
          && [ "$(${pkgs.jq}/bin/jq -c . "$HOME/proj/.claude/settings.local.json")" = '{"permissions":{"allow":["Bash(ls)"]}}' ]; then
          ok "a launch drops the MCP servers and local settings a session planted, keeping claude's permission rules"
        else
          fail "a launch keeps what a session planted for the next one"
        fi

        # The untracked-file preview hands git diff its path after --: git obeys
        # an option even after its paths, so an untracked --output=flake.nix
        # would truncate flake.nix just by being shown.
        untracked='. ${self}/.config/shell/functions/git.bash
          git() { pwd; }
          __git_diff_untracked'
        case "$(${self}/bin/zsh -f -c "$untracked")" in
          *"--no-index --color=always -- /dev/null {} "*) ok "the untracked-file preview hands git diff its path after --" ;;
          *) fail "the untracked-file preview hands git diff its path where an option goes" ;;
        esac

        # __open_file hands the editor its picks after --: nvim runs a +cmd
        # argument, so a file named "+so x.vim" would source x.vim.
        mkdir -p "$HOME/pick" && : > "$HOME/pick/+so x.vim"
        printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$HOME/stub/ed" && chmod +x "$HOME/stub/ed"
        pick='. ${self}/.config/shell/functions/fm.sh
          fd() { printf "+so x.vim\0"; }
          fzf() { tr "\0" "\n"; }
          __open_file'
        if [ "$(cd "$HOME/pick" && EDITOR=$HOME/stub/ed ${self}/bin/zsh -f -c "$pick")" = "$(printf -- '--\n+so x.vim')" ]; then
          ok "__open_file hands the editor its picks after --"
        else
          fail "__open_file hands the editor its picks where an option goes"
        fi

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
