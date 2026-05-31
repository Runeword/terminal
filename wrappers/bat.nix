{
  pkgs,
  files,
  permeance,
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
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "bat";
      description = "Verify bat finds its bundled config";
      script = ''
        bat_config=$(${self}/bin/bat --config-file 2>/dev/null)
        case "$bat_config" in
          ${self}/*)
            ok "bundled config file points to wrapper ($bat_config)" ;;
          *)
            fail "config file is '$bat_config', expected path under '${self}/'" ;;
        esac
      '';
    };
  };
in
self
