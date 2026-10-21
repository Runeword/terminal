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
    postBuild = permeance.installLauncher {
      binName = "git";
      compiled = true;
      configEnv = {
        GIT_CONFIG_GLOBAL = ".config/git/config";
      };
      flags = [
        "-c"
        "core.excludesFile=${permeance.root}/.config/git/ignore"
        # A repository's own config names the command core.fsmonitor runs,
        # and any git command that reads the index runs it: in a repository
        # a sandbox or VM session planted in a folder it shares, an editor's
        # or a picker's git would run it on the host. The command line
        # outranks a repository's config, so none runs; fsmonitor is not
        # used here otherwise.
        "-c"
        "core.fsmonitor=false"
      ];
      # git-upload-pack / -receive-pack / -upload-archive ship as relative
      # symlinks to `git`, which now resolves to the launcher. The launcher's
      # `-c core.excludesFile=…` prefix would then reach these plumbing
      # commands, which reject `-c` ("unknown switch `c'"), breaking
      # ssh-served fetch/push: bypass points each one at the real git.
      aliasLinks = "bypass";
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

        # Repositories planted in a project folder, as a sandbox or VM session
        # could plant them in the folders it shares, whose config makes any
        # git command that reads their index run a command (core.fsmonitor):
        # a nested .git, which git finds as it finds any repository, and a
        # bare repository, a folder that is itself a git directory, with a
        # work tree. The real git runs both commands, which proves each plant
        # is live. The wrapped one runs neither: its launcher passes
        # core.fsmonitor=false on the command line, which outranks a
        # repository's own config, and the bundled config refuses a bare
        # repository git finds by itself (safe.bareRepository=explicit). One
        # named with --git-dir, as ~/.dotfiles is, still opens.
        real=${pkgs.git}/bin/git
        plant() { # $1 the work tree, $2 its git directory, $3 the marker
          mkdir -p "$1"
          echo x >"$1/file"
          "$real" --git-dir="$2" --work-tree="$1" init -q
          "$real" --git-dir="$2" --work-tree="$1" add file
          "$real" --git-dir="$2" config core.fsmonitor "touch $3; false"
        }
        plant "$TMPDIR/nested" "$TMPDIR/nested/.git" "$TMPDIR/nested-ran"
        plant "$TMPDIR/project" "$TMPDIR/project/planted" "$TMPDIR/bare-ran"
        (cd "$TMPDIR/nested" && "$real" status) >/dev/null 2>&1 || true
        (cd "$TMPDIR/project/planted" && "$real" status) >/dev/null 2>&1 || true
        if [ -e "$TMPDIR/nested-ran" ] && [ -e "$TMPDIR/bare-ran" ]; then
          rm "$TMPDIR/nested-ran" "$TMPDIR/bare-ran"
          (cd "$TMPDIR/nested" && ${self}/bin/git status) >/dev/null 2>&1 || true
          if [ -e "$TMPDIR/nested-ran" ]; then
            fail "git ran the core.fsmonitor of a nested repository"
          else
            ok "git runs no core.fsmonitor a repository's own config names"
          fi
          refusal=$(cd "$TMPDIR/project/planted" && ${self}/bin/git status 2>&1 || true)
          if [ -e "$TMPDIR/bare-ran" ]; then
            fail "git ran the config of a bare repository it found by itself"
          else
            case "$refusal" in
              *"safe.bareRepository"*) ok "git refuses a bare repository it finds by itself" ;;
              *) fail "git does not refuse a bare repository it found by itself: $refusal" ;;
            esac
          fi
        else
          fail "the planted repositories' core.fsmonitor does not run even with the real git, so these checks prove nothing"
        fi
        if ${self}/bin/git --git-dir="$TMPDIR/project/planted" rev-parse --git-dir >/dev/null 2>&1; then
          ok "git still opens a bare repository named with --git-dir"
        else
          fail "git refuses a bare repository named with --git-dir"
        fi

        # Dashed builtins must bypass the launcher — its `-c` prefix would
        # break them, and ssh-served fetch/push with them. `-h` exits 129, so
        # its output is captured: piped under pipefail, the check could never fail.
        usage=$(${self}/bin/git-upload-pack -h 2>&1 || true)
        case "$usage" in
          *"unknown switch"*) fail "git-upload-pack hits the launcher -c prefix" ;;
          *) ok "git-upload-pack bypasses the launcher" ;;
        esac
      '';
    };
  };
in
self
