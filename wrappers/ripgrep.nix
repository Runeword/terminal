{ pkgs }:

pkgs.symlinkJoin {
  name = "ripgrep-with-config";
  paths = [ pkgs.ripgrep ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "ignore" ".config/ignore"}
    ${pkgs.lib.mkConfig "ripgrep/ripgreprc" ".config/ripgrep/ripgreprc"}

    wrapProgram $out/bin/rg \
      --set RIPGREP_CONFIG_PATH "$out/.config/ripgrep/ripgreprc" \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
