{ pkgs, files }:

pkgs.symlinkJoin {
  name = "fd-with-config";
  paths = [ pkgs.fd ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "ignore" ".config/ignore"}

    wrapProgram $out/bin/fd \
      --add-flags "--ignore-file $out/.config/ignore"
  '';
}
