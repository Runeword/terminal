{
  pkgs,
  tools,
  configPath,
  permeance,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };

  config = files.mkConfig "alacritty-config" [ ".config/alacritty" ];

  # The tools' own zsh completions (rg, fd, gh, nix, …), merged into one
  # directory that .zshrc puts on fpath: zsh would otherwise see only its own.
  # A name two tools ship keeps the first one's. The directory sits below the
  # store path rather than being it: compinit asks before loading an fpath
  # directory whose parent is group-writable, as /nix/store is.
  zshCompletions =
    let
      merged = pkgs.runCommand "terminal-zsh-completions" { } ''
        dest=$out/share/zsh/site-functions
        mkdir -p "$dest"
        for dir in ${pkgs.lib.concatMapStringsSep " " (pkg: "${pkg}/share/zsh/site-functions") tools}; do
          for f in "$dir"/*; do
            [ -e "$f" ] && [ ! -e "$dest/''${f##*/}" ] && ln -s "$f" "$dest/"
          done
        done
        true
      '';
    in
    "${merged}/share/zsh/site-functions";

  # The tools' bin directories, ahead of the inherited PATH in every shell the
  # terminal opens; the smoke test resolves commands against the same list.
  pathPrefix = map (pkg: "${pkgs.lib.getBin pkg}/bin") tools;

  fonts = pkgs.lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
    pkgs.nerd-fonts.sauce-code-pro
    pkgs.nerd-fonts.monaspace
    pkgs.nerd-fonts.caskaydia-mono
  ];
  self =
    pkgs.runCommand "alacritty"
      {
        passthru.tests.smoke = permeance.tests.mkSmoke {
          name = "alacritty";
          description = "Verify the alacritty launcher execs the real binary headlessly";
          script = ''
            # A GUI terminal can't open a window in the sandbox, but --version runs
            # headless and proves the launcher resolves PERMEANCE_ROOT and execs the
            # real alacritty with its injected flags.
            if v=$(env -u DISPLAY -u WAYLAND_DISPLAY ${self}/bin/alacritty --version 2>&1); then
              case "$v" in
              alacritty*) ok "launcher execs alacritty ($v)" ;;
              *) fail "unexpected --version output: $v" ;;
              esac
            else
              fail "alacritty launcher failed to exec (--version)"
            fi

            # The tools' completions reach zsh as one directory the launcher
            # exports (ripgrep's _rg among them).
            if [ -e ${zshCompletions}/_rg ] && grep -q "TERMINAL_ZSH_COMPLETIONS" ${self}/bin/alacritty; then
              ok "the launcher exports the tools' zsh completions, _rg included"
            else
              fail "the tools' zsh completions are not exported (or lack _rg)"
            fi

            # compinit audits fpath before loading it, and asks at the first
            # prompt if a directory or its parent is group-writable, as
            # /nix/store is. The audit trusts a user's own group, and the build
            # user's owns the build's /nix/store: LOGNAME names someone else.
            if LOGNAME=nobody ${pkgs.zsh}/bin/zsh -fc 'autoload -Uz compaudit && compaudit "$1"' zsh ${zshCompletions} > /dev/null 2>&1; then
              ok "zsh's compaudit accepts the completions directory"
            else
              fail "zsh's compaudit rejects the completions directory, so compinit would ask"
            fi

            # np, npr and nps (__nix_package, .config/shell/functions/nix.sh) pipe
            # nix-search-tv's nixpkgs index into fzf, which previews each package
            # with nix-search-tv again: without it on the terminal's PATH the picker
            # opens empty. Its index is fetched from the network, so this only
            # runs the binary.
            terminalPath=${pkgs.lib.concatStringsSep ":" pathPrefix}
            for cmd in nix-search-tv fzf; do
              if PATH="$terminalPath" command -v "$cmd" > /dev/null; then
                ok "on the terminal's PATH, for np, npr and nps: $cmd"
              else
                fail "not on the terminal's PATH, so np, npr and nps open an empty picker: $cmd"
              fi
            done
            if PATH="$terminalPath" nix-search-tv --help > /dev/null 2>&1; then
              ok "nix-search-tv runs from the terminal's PATH"
            else
              fail "nix-search-tv does not run from the terminal's PATH"
            fi
          '';
        };
      }
      ''
        mkdir -p $out
        ln -s ${config}/.config $out/.config

        ${permeance.installLauncher {
          binName = "alacritty";
          compiled = true;
          realBin = "${pkgs.alacritty}/bin/alacritty";
          unsetEnv = [
            "TMUX"
            "TMUX_PANE"
          ];
          inherit pathPrefix;
          staticEnv = {
            TERMINAL_ZSH_COMPLETIONS = "${zshCompletions}";
          }
          // pkgs.lib.optionalAttrs (fonts != [ ]) {
            FONTCONFIG_FILE = "${pkgs.makeFontsConf { fontDirectories = fonts; }}";
          };
          flags = [
            "--config-file"
            "${permeance.root}/.config/alacritty/alacritty.toml"
          ];
        }}
      '';
in
self
