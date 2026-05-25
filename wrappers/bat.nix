{
  pkgs,
  files,
  tests,
}:

let
  config = files.mkConfig "bat-config" [
    {
      source = ".config/bat";
      target = ".config/bat";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "bat-with-config";
    paths = [
      pkgs.bat
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/bat \
        --set BAT_CONFIG_PATH "$out/.config/bat/config"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "bat";
      description = "Verify bat finds its config file";
      script = ''
        bat_config=$(${self}/bin/bat --config-file 2>/dev/null)
        case "$bat_config" in
          ${self}/*)
            ok "config file points to wrapper ($bat_config)" ;;
          *)
            fail "config file is '$bat_config', expected path under '${self}/'" ;;
        esac
      '';
    };
  };
in
self
