{ pkgs, files }:

pkgs.symlinkJoin {
  name = "starship-with-config";
  paths = [ pkgs.starship ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "starship.toml" ".config/starship.toml"}

    wrapProgram $out/bin/starship \
      --set STARSHIP_CONFIG "$out/.config/starship.toml"
  '';
}
