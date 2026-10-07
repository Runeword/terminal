{
  pkgs,
  files,
  permeance,
}:

let
  config = files.mkConfig "git-config" [
    ".config/git/config"
    ".config/git/ignore"
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

        # SSH-signing scaffolding is wired (gpg.format + user.signingkey), but
        # auto-sign is deferred (commit.gpgsign=false) until hardware keys land:
        # a passphrase-protected key can't sign in the non-interactive lefthook
        # auto-commit hook (no TTY for the prompt). Assert both — flip the
        # gpgsign expectation to "true" when signing is turned back on.
        fmt=$(${self}/bin/git config --global --get gpg.format 2>/dev/null)
        if [ "$fmt" = "ssh" ]; then
          ok "gpg.format=ssh loaded (SSH signing configured)"
        else
          fail "gpg.format is '$fmt', expected 'ssh'"
        fi

        sign=$(${self}/bin/git config --global --get commit.gpgsign 2>/dev/null)
        if [ "$sign" = "false" ]; then
          ok "commit.gpgsign=false (auto-sign deferred, scaffolding wired)"
        else
          fail "commit.gpgsign is '$sign', expected 'false'"
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
