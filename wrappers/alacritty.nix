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
in
pkgs.runCommand "alacritty" { } ''
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
''
