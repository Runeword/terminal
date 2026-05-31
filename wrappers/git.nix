{
  pkgs,
  files,
  permeance,
}:

let
  config = files.mkConfig "git-config" [
    ".config/git/config"
    ".config/git/ignore"
    # Bundled here too so [include] path = ../delta/config resolves within
    # this wrapper's own output. Otherwise the include silently misses and
    # delta.* keys aren't visible via `git config`.
    ".config/delta/config"
  ];
  self = pkgs.symlinkJoin {
    name = "git-with-config";
    paths = [
      pkgs.git
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "git";
      configEnv = {
        GIT_CONFIG_GLOBAL = ".config/git/config";
      };
      flags = [
        "-c"
        "core.excludesFile=$PERMEANCE_ROOT/.config/git/ignore"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "git";
      description = "Verify git loads bundled global config";
      script = ''
        moved=$(${self}/bin/git config --global --get diff.colorMoved 2>/dev/null)
        if [ "$moved" = "zebra" ]; then
          ok "diff.colorMoved=zebra loaded from bundled global config"
        else
          fail "diff.colorMoved is '$moved', expected 'zebra'"
        fi

        pager=$(${self}/bin/git config --global --get core.pager 2>/dev/null)
        if [ "$pager" = "delta" ]; then
          ok "core.pager=delta loaded"
        else
          fail "core.pager is '$pager', expected 'delta'"
        fi

        # The [include] should pull delta.* keys into git config. --global
        # requires explicit --includes to follow include directives, but
        # unrestricted lookups (which is what delta does when reading config)
        # follow them by default. Verify with --includes here.
        theme=$(${self}/bin/git config --global --includes --get delta.syntax-theme 2>/dev/null)
        if [ "$theme" = "none" ]; then
          ok "delta.* keys reachable via [include] path = ../delta/config"
        else
          fail "delta.syntax-theme is '$theme', expected 'none' via include"
        fi
      '';
    };
  };
in
self
