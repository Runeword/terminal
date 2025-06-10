{
  pkgs,
  extraPackages,
  extraFonts,
}:
# let
  # extraWrapper = pkgs.callPackage ./extra.nix {
  #   inherit pkgs extraPackages;
  #   extraConfigs = {
  #     bat = "extraConfig/bat";
  #   };
  # };
# in
pkgs.runCommand "alacritty"
  {
    nativeBuildInputs = [ pkgs.makeWrapper ];
  }
  ''
    ${pkgs.lib.mkLink "config/alacritty" ".config/alacritty"}

    # use makeWrapper instead of wrapProgram to preserve the original process name 'alacritty'
    # wrapProgram would have named it alacritty-wrapped instead
    mkdir -p $out/bin
    makeWrapper ${pkgs.alacritty}/bin/alacritty $out/bin/alacritty \
    --prefix PATH : ${pkgs.lib.makeBinPath extraPackages} \
    --set FONTCONFIG_FILE ${pkgs.makeFontsConf { fontDirectories = extraFonts; }} \
    --add-flags "--config-file $out/.config/alacritty/alacritty.toml" \
  ''
  # --prefix PATH : ${extraWrapper}/bin \
  # --set TERMINFO_DIRS "${pkgs.alacritty}/share/terminfo" \
