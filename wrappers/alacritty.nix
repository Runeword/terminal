{
  pkgs,
  tools,
  configPath,
}:
let

  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };

  config = files.mkConfig "alacritty-config" [
    {
      source = ".config/alacritty";
      target = ".config/alacritty";
    }
  ];

  fonts = pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
    pkgs.nerd-fonts.sauce-code-pro
    pkgs.nerd-fonts.monaspace
    pkgs.nerd-fonts.caskaydia-mono
  ];
in
pkgs.runCommand "alacritty"
  {
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
  }
  ''
    mkdir -p $out
    ln -s ${config}/.config $out/.config

    # makeBinaryWrapper compiles a tiny C launcher (no bash indirection per launch).
    # Bare make*Wrapper instead of wrapProgram to preserve the original process name 'alacritty'.
    mkdir -p $out/bin
    makeBinaryWrapper ${pkgs.alacritty}/bin/alacritty $out/bin/alacritty \
      --unset TMUX \
      --unset TMUX_PANE \
      --prefix PATH : ${pkgs.lib.makeBinPath tools} \
      ${
        pkgs.lib.optionalString (fonts != [ ])
          "--set FONTCONFIG_FILE ${pkgs.makeFontsConf { fontDirectories = fonts; }}"
      } \
      --add-flags "--config-file $out/.config/alacritty/alacritty.toml"
  ''
