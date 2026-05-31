{
  pkgs,
  files,
  permeance,
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
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "ripgrep";
      description = "Verify ripgrep respects the bundled ignore file";
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
      '';
    };
  };
in
self
