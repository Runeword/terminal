{
  pkgs,
  extraPackages,
  useLink ? false,
  configRoot ? ../config,
}:
let
  fonts = pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
    pkgs.nerd-fonts.sauce-code-pro
    pkgs.nerd-fonts.monaspace
    pkgs.nerd-fonts.caskaydia-mono
  ];

  mkConfig = path: target:
    if useLink
    then pkgs.lib.mkLink "config/${path}" target
    else pkgs.lib.mkCopy "${configRoot}/${path}" target;
in
pkgs.runCommand "alacritty"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  }
  ''
    ${mkConfig "alacritty" ".config/alacritty"}

    # use makeWrapper instead of wrapProgram to preserve the original process name 'alacritty'
    # wrapProgram would have named it alacritty-wrapped instead
    mkdir -p $out/bin
    makeWrapper ${pkgs.alacritty}/bin/alacritty $out/bin/alacritty \
      --prefix PATH : ${pkgs.lib.makeBinPath extraPackages} \
      ${pkgs.lib.optionalString (fonts != []) "--set FONTCONFIG_FILE ${pkgs.makeFontsConf { fontDirectories = fonts; }}"} \
      --add-flags "--config-file $out/.config/alacritty/alacritty.toml"
  ''
