{ pkgs }:

pkgs.symlinkJoin {
  name = "ripgrep-with-config";
  paths = [ pkgs.ripgrep ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "ripgrep" ".config/ripgrep"}

    wrapProgram $out/bin/rg \
      --set RIPGREP_CONFIG_PATH "$out/.config/ripgrep/ripgreprc" \
      --add-flags "--ignore-file $out/.config/ripgrep/ignore"
  '';
}
