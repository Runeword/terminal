{
  pkgs,
  files,
  permeance,
}:

let
  config = files.mkConfig "starship-config" [ ".config/starship/starship.toml" ];
  self = pkgs.symlinkJoin {
    name = "starship-with-config";
    paths = [
      pkgs.starship
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "starship";
      configEnv = {
        STARSHIP_CONFIG = ".config/starship/starship.toml";
      };
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "starship";
      description = "Verify starship loads its bundled config";
      script = ''
        if ${self}/bin/starship prompt > /dev/null 2>&1; then
          ok "bundled config loads (prompt generates)"
        else
          fail "prompt generation failed"
        fi
      '';
    };
  };
in
self
