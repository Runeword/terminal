{ pkgs }:

pkgs.symlinkJoin {
  name = "delta-with-config";
  paths = [ pkgs.delta ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "delta/config" ".config/delta/config"}

    wrapProgram $out/bin/delta \
      --add-flags "--config $out/.config/delta/config"
  '';
}
