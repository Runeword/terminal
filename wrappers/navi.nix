{
  pkgs,
  files,
  tests,
}:

let
  config = files.mkConfig "navi-config" [
    {
      source = ".config/navi";
      target = ".config/navi";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "navi-with-config";
    paths = [
      pkgs.navi
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/navi \
        --set NAVI_CONFIG "$out/.config/navi/config.yaml" \
        --set NAVI_PATH "$out/.config/navi"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "navi";
      description = "Verify navi loads its config";
      script = ''
        # navi info config-path shows the active config path; fails on bad config.
        if ${self}/bin/navi info config-path > /dev/null 2>&1; then
          ok "config loads"
        else
          fail "config failed to load"
        fi
      '';
    };
  };
in
self
