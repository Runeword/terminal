{ pkgs, files }:

pkgs.symlinkJoin {
  name = "ripgrep-with-config";
  paths = [ pkgs.ripgrep ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "ignore" ".config/ignore"}
    ${files.sync "ripgrep/ripgreprc" ".config/ripgrep/ripgreprc"}

    wrapProgram $out/bin/rg \
      --set RIPGREP_CONFIG_PATH "$out/.config/ripgrep/ripgreprc" \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
