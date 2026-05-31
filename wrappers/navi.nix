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
        # navi info config-path shows the active config path; fails on bad config.
        if ${self}/bin/navi info config-path > /dev/null 2>&1; then
          ok "bundled config loads"
        else
          fail "bundled config failed to load"
        fi
      '';
    };
  };
in
self
