{
  pkgs,
  files,
  tests,
}:

let
  self = pkgs.symlinkJoin {
    name = "starship-with-config";
    paths = [ pkgs.starship ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      ${files.sync "starship.toml" ".config/starship.toml"}

      wrapProgram $out/bin/starship \
        --set STARSHIP_CONFIG "$out/.config/starship.toml"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "starship";
      description = "Verify starship loads its config and generates a prompt";
      script = ''
        if ${self}/bin/starship prompt > /dev/null 2>&1; then
          ok "prompt generates successfully"
        else
          fail "prompt generation failed"
        fi
      '';
    };
  };
in
self
