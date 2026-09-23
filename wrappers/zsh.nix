{
  pkgs,
  files,
  permeance,
  claude,
}:

let
  # The leader-key picker (.config/shell/functions/aliases.sh) renders the
  # bundled .config/shell/leader.toml through this binary; the smoke test
  # exercises that path against the wrapper's own copy of the table.
  leaderAliases = import ../packages/custom/leader-aliases { inherit pkgs; };
  config = files.mkConfig "zsh-config" [
    ".config/zsh"
    ".config/shell"
    ".config/readline"
    ".config/direnv"
  ];
  self = pkgs.symlinkJoin {
    name = "zsh-with-config";
    paths = [
      pkgs.zsh
      pkgs.zsh-autosuggestions
      config
    ];
    postBuild = ''
      mkdir -p $out/paths
      ln -s ${claude} $out/paths/claude

      ${permeance.installLauncher {
        binName = "zsh";
        configEnv = {
          ZDOTDIR = ".config/zsh";
          INPUTRC = ".config/readline/inputrc";
          DIRENV_CONFIG = ".config/direnv";
        };
        staticEnv = {
          NIX_OUT_SHELL = "@OUT@";
        };
        flags = [ "--no-global-rcs" ];
      }}
    '';
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "zsh";
      description = "Verify zsh wrapper exec's the real binary, the leader table renders, and the git picker state helper round-trips";
      script = ''
        if ${self}/bin/zsh --version > /dev/null 2>&1; then
          ok "wrapper execs real zsh"
        else
          fail "wrapper does not exec real zsh"
        fi

        # A leader.toml that fails to render leaves every chord dead, so check
        # the fields the widget reads (raw command, mode) for a known chord.
        sep=$(printf '\302\240')
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.toml \
          | awk -F "$sep" '$1 ~ /^gt +$/ && $5 == "git status" && $6 == "run" { found = 1 } END { exit !found }'; then
          ok "bundled leader.toml renders and binds gt to git status"
        else
          fail "bundled leader.toml does not render the gt chord"
        fi

        # The two-level git file picker (ga/gru/grd/gsp, __git_pick_files in
        # .config/shell/functions/git.bash) keeps whole-file selection in fzf's
        # NATIVE multi-select (instant Tab, no subprocess) and tracks only drilled
        # hunk subsets through this state helper. The picker itself is interactive
        # fzf, so assert the helper's state logic here: a set/get round-trip, the
        # partial preview hint, and post's two emitted fzf actions (reload-free
        # select vs. the finalize become that dumps the native selection to .whole).
        gfs=${self}/.config/shell/scripts/git-file-select.sh
        sd=$(mktemp -d)
        sh "$gfs" set "$sd" "src/app.ts" ALL
        sh "$gfs" set "$sd" "lib/y.ts" "0 2"
        if [ "$(sh "$gfs" get "$sd" src/app.ts)" = ALL ] \
          && [ "$(sh "$gfs" get "$sd" lib/y.ts)" = "0 2" ] \
          && [ -z "$(sh "$gfs" get "$sd" absent.ts)" ]; then
          ok "git-file-select set/get round-trips whole and subset specs"
        else
          fail "git-file-select set/get lost a spec"
        fi

        # A drilled subset surfaces a preview hint; whole/none stay silent because
        # fzf's own marker already shows them.
        if [ "$(sh "$gfs" hint "$sd" lib/y.ts)" = "◐ hunks: 0 2" ] \
          && [ -z "$(sh "$gfs" hint "$sd" src/app.ts)" ]; then
          ok "git-file-select hint flags a partial file, silent for whole"
        else
          fail "git-file-select hint wrong"
        fi

        # post without .execute reflects the drilled spec as a native, reload-free
        # select/deselect; with .execute it emits the finalize become that writes
        # .whole and .commit (a reload would wipe every native mark, so it must not).
        # Check both no-.execute cases before creating the sentinel.
        selact=$(sh "$gfs" post "$sd" lib/y.ts)
        deselact=$(sh "$gfs" post "$sd" absent.ts)
        : > "$sd/.execute"
        exc=$(sh "$gfs" post "$sd" lib/y.ts)
        case "$exc" in
          select+become*".whole"*"/.commit)") gotbecome=1 ;;
          *) gotbecome=0 ;;
        esac
        if [ "$selact" = select ] && [ "$deselact" = deselect ] && [ "$gotbecome" = 1 ]; then
          ok "git-file-select post emits reload-free select/deselect and a finalize become"
        else
          fail "git-file-select post: sel='$selact' desel='$deselact' exec='$exc'"
        fi
        rm -rf "$sd"
      '';
    };
  };
in
self
