{
  pkgs,
  files,
  permeance,
  tests,
}:

let
  config = files.mkConfig "delta-config" [ ".config/delta/config" ];
  self = pkgs.symlinkJoin {
    name = "delta-with-config";
    paths = [
      pkgs.delta
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "delta";
      flags = [
        "--config"
        "$PERMEANCE_ROOT/.config/delta/config"
      ];
    };
    passthru.tests.smoke = tests.smoke {
      name = "delta";
      description = "Verify delta loads its bundled config and the launcher resolves PERMEANCE_ROOT";
      script = ''
        # --show-config prints the merged effective config. Grep for a value that
        # differs from delta's defaults (file-modified-label defaults to a glyph,
        # not '~'), so a passing test proves our config was actually loaded.
        cfg=$(${self}/bin/delta --show-config 2>/dev/null)
        if echo "$cfg" | grep -qE '^[[:space:]]*file-modified-label[[:space:]]*=[[:space:]]*~[[:space:]]*$'; then
          ok "config-driven file-modified-label loaded"
        else
          fail "file-modified-label not '~' — config did not load"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/delta \
           && grep -qF '/.config/delta/config' ${self}/bin/delta; then
          ok "launcher passes --config from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for --config"
        fi
      '';
    };
  };
in
self
