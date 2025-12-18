{ pkgs }:

pkgs.symlinkJoin {
  name = "fd-with-config";
  paths = [ pkgs.fd ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "ignore" ".config/ignore"}

    wrapProgram $out/bin/fd \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
