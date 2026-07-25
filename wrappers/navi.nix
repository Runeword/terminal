{
  pkgs,
  files,
  permeance,
}:

let
  config = files.mkConfig "navi-config" [ ".config/navi" ];
  self = pkgs.symlinkJoin {
    name = "navi-with-config";
    paths = [
      pkgs.navi
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "navi";
      configEnv = {
        NAVI_CONFIG = ".config/navi/config.yaml";
        NAVI_PATH = ".config/navi";
      };
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "navi";
      description = "Verify navi loads its bundled config";
      script = ''
        # navi exits 0 (and silently falls back to a default config) when it
        # can't parse the bundled one — it only warns on stderr — so an exit
        # check can't see a broken config. Assert navi read the config with no
        # parse error on stderr.
        err=$(${self}/bin/navi info config-path 2>&1 >/dev/null)
        if printf '%s' "$err" | grep -qiE "error parsing config|parse error"; then
          fail "navi reported a config parse error: $err"
        else
          ok "bundled config parses (no parse error on stderr)"
        fi
      '';
    };
  };
in
self
