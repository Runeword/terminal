{ pkgs }:

pkgs.symlinkJoin {
  name = "direnv-with-config";
  paths = [ pkgs.direnv ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "direnv" ".config/direnv"}

    wrapProgram $out/bin/direnv \
      --set DIRENV_CONFIG "$out/.config/direnv"
  '';
}
