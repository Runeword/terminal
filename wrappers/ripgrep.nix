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
      compiled = true;
      configEnv = {
        RIPGREP_CONFIG_PATH = ".config/ripgrep/ripgreprc";
      };
      flags = [
        "--ignore-file"
        "${permeance.root}/.config/ignore"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "ripgrep";
      description = "Verify ripgrep respects the bundled ignore file, which hides no project's own go/pkg or .local";
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

        # rg anchors an --ignore-file's patterns at its working directory, so
        # an anchored entry (one for $HOME's own trees) would hide a project's
        # own go/pkg or .local wherever rg runs.
        mkdir -p $TMPDIR/rg-proj/go/pkg $TMPDIR/rg-proj/.local
        echo "x" > $TMPDIR/rg-proj/go/pkg/a.txt
        echo "x" > $TMPDIR/rg-proj/.local/b.txt
        if [ "$(cd $TMPDIR/rg-proj && ${self}/bin/rg --files --hidden 2>/dev/null | sort | tr '\n' ' ')" = ".local/b.txt go/pkg/a.txt " ]; then
          ok "a project's own go/pkg and .local are searched"
        else
          fail "the bundled ignore file hides a project's own go/pkg or .local"
        fi
      '';
    };
  };
in
self
