{
  pkgs,
  files,
  permeance,
  tests,
}:

let
  config = files.mkConfig "fd-config" [ ".config/ignore" ];
  self = pkgs.symlinkJoin {
    name = "fd-with-config";
    paths = [
      pkgs.fd
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "fd";
      flags = [
        "--ignore-file"
        "$PERMEANCE_ROOT/.config/ignore"
      ];
    };
    passthru.tests.smoke = tests.smoke {
      name = "fd";
      description = "Verify fd respects the bundled ignore file and the launcher resolves PERMEANCE_ROOT";
      script = ''
        mkdir -p $TMPDIR/fd-test/node_modules
        echo "secret" > $TMPDIR/fd-test/node_modules/file.txt
        echo "visible" > $TMPDIR/fd-test/visible.txt

        fd_output=$(${self}/bin/fd . $TMPDIR/fd-test 2>/dev/null)
        echo "  files found:"
        echo "$fd_output" | sed 's/^/    /'

        if echo "$fd_output" | grep -q "node_modules"; then
          fail "node_modules not ignored"
        else
          ok "node_modules ignored via bundled config"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/fd \
           && grep -qF '/.config/ignore' ${self}/bin/fd; then
          ok "launcher passes --ignore-file from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for --ignore-file"
        fi
      '';
    };
  };
in
self
