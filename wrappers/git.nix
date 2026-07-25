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
    postBuild =
      permeance.installLauncher {
        binName = "git";
        configEnv = {
          GIT_CONFIG_GLOBAL = ".config/git/config";
        };
        flags = [
          "-c"
          "core.excludesFile=$PERMEANCE_ROOT/.config/git/ignore"
        ];
      }
      # git-upload-pack / -receive-pack / -upload-archive ship as relative
      # symlinks to `git`, which now resolves to the launcher. The launcher's
      # `-c core.excludesFile=…` prefix then reaches these plumbing commands,
      # which reject `-c` ("unknown switch `c'"), breaking ssh-served
      # fetch/push. Repoint every dashed-builtin symlink at the real git.
      + ''
        for l in "$out"/bin/*; do
          if [ -L "$l" ] && [ "$(readlink "$l")" = "git" ]; then
            ln -sf .git-real "$l"
          fi
        done
      '';
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

        # Dashed builtins must bypass the launcher — its `-c` prefix would
        # break them, and ssh-served fetch/push with them.
        if ${self}/bin/git-upload-pack -h 2>&1 | grep -q "unknown switch"; then
          fail "git-upload-pack hits the launcher -c prefix"
        else
          ok "git-upload-pack bypasses the launcher"
        fi
      '';
    };
  };
in
self
