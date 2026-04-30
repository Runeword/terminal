{
  pkgs,
  files,
  tests,
}:

let
  config = files.mkConfig "starship-config" [
    {
      source = "starship.toml";
      target = ".config/starship.toml";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "starship-with-config";
    paths = [
      pkgs.starship
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
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
