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
        # starship exits 0 even when it can't parse the config — it prints an
        # error to stderr and falls back to defaults — so an exit check can't see
        # a broken config. Assert the prompt renders and no parse error surfaced.
        err=$(${self}/bin/starship prompt 2>&1 >/dev/null)
        prompt=$(${self}/bin/starship prompt 2>/dev/null)
        if printf '%s' "$err" | grep -qiE "parse error|unable to parse|error parsing"; then
          fail "starship reported a config parse error: $err"
        elif [ -n "$prompt" ]; then
          ok "bundled config parses and prompt renders"
        else
          fail "prompt was empty"
        fi
      '';
    };
  };
in
self
