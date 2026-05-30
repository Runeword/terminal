{
  pkgs,
  files,
  permeance,
  tests,
}:

let
  config = files.mkConfig "ripgrep-config" [
    ".config/ignore"
    ".config/ripgrep/ripgreprc"
  ];
  self = pkgs.symlinkJoin {
    name = "ripgrep-with-config";
    paths = [
      pkgs.ripgrep
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "rg";
      configEnv = {
        RIPGREP_CONFIG_PATH = ".config/ripgrep/ripgreprc";
      };
      flags = [
        "--ignore-file"
        "$PERMEANCE_ROOT/.config/ignore"
      ];
    };
    passthru.tests.smoke = tests.smoke {
      name = "ripgrep";
      description = "Verify ripgrep respects the bundled ignore file and the launcher resolves PERMEANCE_ROOT";
      script = ''
        mkdir -p $TMPDIR/rg-test/node_modules
        echo "secret" > $TMPDIR/rg-test/node_modules/file.txt
        echo "visible" > $TMPDIR/rg-test/visible.txt

        rg_output=$(${self}/bin/rg --files $TMPDIR/rg-test 2>/dev/null)
        echo "  files found:"
        echo "$rg_output" | sed 's/^/    /'

        if echo "$rg_output" | grep -q "node_modules"; then
          fail "node_modules not ignored"
        else
          ok "node_modules ignored via bundled config"
        fi

        if echo "$rg_output" | grep -q "visible.txt"; then
          ok "visible files found"
        else
          fail "visible files not found"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/rg \
           && grep -qF '/.config/ripgrep/ripgreprc' ${self}/bin/rg \
           && grep -qF '/.config/ignore' ${self}/bin/rg; then
          ok "launcher resolves RIPGREP_CONFIG_PATH and --ignore-file from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution"
        fi
      '';
    };
  };
in
self
