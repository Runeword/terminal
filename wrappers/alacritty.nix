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

  fonts = pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
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
          '';
        };
      }
      ''
        mkdir -p $out
        ln -s ${config}/.config $out/.config

        ${permeance.installLauncher {
          binName = "alacritty";
          realBin = "${pkgs.alacritty}/bin/alacritty";
          unsetEnv = [
            "TMUX"
            "TMUX_PANE"
          ];
          pathPrefix = [ (pkgs.lib.makeBinPath tools) ];
          staticEnv = pkgs.lib.optionalAttrs (fonts != [ ]) {
            FONTCONFIG_FILE = "${pkgs.makeFontsConf { fontDirectories = fonts; }}";
          };
          flags = [
            "--config-file"
            "$PERMEANCE_ROOT/.config/alacritty/alacritty.toml"
          ];
        }}
      '';
in
self
