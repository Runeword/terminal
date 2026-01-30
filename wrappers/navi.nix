{ pkgs, files }:

pkgs.symlinkJoin {
  name = "navi-with-config";
  paths = [ pkgs.navi ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "navi" ".config/navi"}

    wrapProgram $out/bin/navi \
      --set NAVI_CONFIG "$out/.config/navi/config.yaml" \
      --set NAVI_PATH "$out/.config/navi"
  '';
}
