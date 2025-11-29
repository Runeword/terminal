{ pkgs }:

pkgs.symlinkJoin {
  name = "fd-with-config";
  paths = [ pkgs.fd ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkLink "fd" ".config/fd"}

    wrapProgram $out/bin/fd \
      --add-flags "--ignore-file $out/.config/fd/ignore"
  '';
}
