{
  pkgs,
  files,
  permeance,
  tests,
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
    passthru.tests.smoke = tests.smoke {
      name = "starship";
      description = "Verify starship loads its bundled config and the launcher resolves PERMEANCE_ROOT";
      script = ''
        if ${self}/bin/starship prompt > /dev/null 2>&1; then
          ok "bundled config loads (prompt generates)"
        else
          fail "prompt generation failed"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/starship \
           && grep -qF '/.config/starship/starship.toml' ${self}/bin/starship; then
          ok "launcher resolves STARSHIP_CONFIG from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for STARSHIP_CONFIG"
        fi
      '';
    };
  };
in
self
