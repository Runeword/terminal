{
  pkgs,
  files,
  tests,
}:

let
  self = pkgs.symlinkJoin {
    name = "fd-with-config";
    paths = [ pkgs.fd ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      ${files.sync "ignore" ".config/ignore"}

      wrapProgram $out/bin/fd \
        --add-flags "--ignore-file $out/.config/ignore"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "fd";
      description = "Verify fd respects the shared ignore file";
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
          ok "node_modules ignored"
        fi
      '';
    };
  };
in
self
