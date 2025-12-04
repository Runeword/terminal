{ pkgs, mkConfig }:

pkgs.symlinkJoin {
  name = "bat-with-config";
  paths = [ pkgs.bat ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "bat" ".config/bat"}

    wrapProgram $out/bin/bat \
      --set BAT_CONFIG_PATH "$out/.config/bat/config"
  '';
}
