{
  pkgs,
  files,
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
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/rg \
        --set RIPGREP_CONFIG_PATH "$out/.config/ripgrep/ripgreprc" \
        --add-flags "--ignore-file $out/.config/ignore"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "ripgrep";
      description = "Verify ripgrep respects the shared ignore file";
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
          ok "node_modules ignored"
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
