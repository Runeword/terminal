{ pkgs }:

pkgs.symlinkJoin {
  name = "bat-with-config";
  paths = [ pkgs.bat ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "config/bat" ".config/bat"}

    wrapProgram $out/bin/bat \
      --set BAT_CONFIG_DIR "$out/.config/bat" \
  '';
}
