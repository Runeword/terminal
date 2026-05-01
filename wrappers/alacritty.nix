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
      source = "alacritty";
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
    nativeBuildInputs = [ pkgs.makeWrapper ];
  }
  ''
    mkdir -p $out
    ln -s ${config}/.config $out/.config

    # use makeWrapper instead of wrapProgram to preserve the original process name 'alacritty'
    # wrapProgram would have named it alacritty-wrapped instead
    mkdir -p $out/bin
    makeWrapper ${pkgs.alacritty}/bin/alacritty $out/bin/alacritty \
      --unset TMUX \
      --unset TMUX_PANE \
      --prefix PATH : ${pkgs.lib.makeBinPath tools} \
      ${
        pkgs.lib.optionalString (fonts != [ ])
          "--set FONTCONFIG_FILE ${pkgs.makeFontsConf { fontDirectories = fonts; }}"
      } \
      --add-flags "--config-file $out/.config/alacritty/alacritty.toml"
  ''
