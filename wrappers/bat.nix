{
  pkgs,
  files,
  permeance,
  tests,
}:

let
  config = files.mkConfig "bat-config" [ ".config/bat" ];
  self = pkgs.symlinkJoin {
    name = "bat-with-config";
    paths = [
      pkgs.bat
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "bat";
      configEnv = {
        BAT_CONFIG_PATH = ".config/bat/config";
      };
    };
    passthru.tests.smoke = tests.smoke {
      name = "bat";
      description = "Verify bat finds its bundled config and the launcher resolves PERMEANCE_ROOT";
      script = ''
        bat_config=$(${self}/bin/bat --config-file 2>/dev/null)
        case "$bat_config" in
          ${self}/*)
            ok "bundled config file points to wrapper ($bat_config)" ;;
          *)
            fail "config file is '$bat_config', expected path under '${self}/'" ;;
        esac

        if grep -q PERMEANCE_ROOT ${self}/bin/bat \
           && grep -qF '/.config/bat/config' ${self}/bin/bat; then
          ok "launcher resolves BAT_CONFIG_PATH from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for BAT_CONFIG_PATH"
        fi
      '';
    };
  };
in
self
