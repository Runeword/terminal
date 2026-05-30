{
  pkgs,
  files,
  permeance,
  tests,
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
    passthru.tests.smoke = tests.smoke {
      name = "navi";
      description = "Verify navi loads its bundled config and the launcher resolves PERMEANCE_ROOT";
      script = ''
        # navi info config-path shows the active config path; fails on bad config.
        if ${self}/bin/navi info config-path > /dev/null 2>&1; then
          ok "bundled config loads"
        else
          fail "bundled config failed to load"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/navi \
           && grep -qF '/.config/navi/config.yaml' ${self}/bin/navi \
           && grep -qE 'NAVI_PATH=.*PERMEANCE_ROOT' ${self}/bin/navi; then
          ok "launcher resolves NAVI_CONFIG and NAVI_PATH from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for NAVI_CONFIG/NAVI_PATH"
        fi
      '';
    };
  };
in
self
