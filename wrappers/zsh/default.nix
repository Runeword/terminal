{
  pkgs,
  files,
  permeance,
  claude,
}:

let
  inherit (pkgs) lib;
  config = files.mkConfig "zsh-config" [
    ".config/zsh"
    ".config/shell"
    ".config/readline"
    ".config/direnv"
  ];
  # Tools only the tests use. The leader-key picker (the
  # .config/zsh/plugins/leader-aliases plugin) renders the bundled
  # .config/shell/leader.conf through leader-aliases, and leader-aliases-edit
  # lines it up with it; Shift+Tab's search (.config/shell/scripts/fm_rg.sh)
  # matches through fm-query; gl's and gda/gdc/gdd's rows (log-rows,
  # path-rows) and gl's file tree come from hunk-pick.
  leaderAliases = import ../../packages/leader-aliases { inherit pkgs; };
  fmQuery = import ../../packages/fm-query { inherit pkgs; };
  hunkPick = import ../../packages/git/hunk-pick { inherit pkgs; };
in
pkgs.symlinkJoin (finalAttrs: {
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
      compiled = true;
      configEnv = {
        ZDOTDIR = ".config/zsh";
        INPUTRC = ".config/readline/inputrc";
        DIRENV_CONFIG = ".config/direnv";
      };
      staticEnv = {
        NIX_OUT_SHELL = permeance.out;
      };
      flags = [ "--no-global-rcs" ];
    }}
  '';

  # One check per tests/<topic>.sh, a template: its row gives the topic's
  # description and the store paths its @…@ placeholders stand for, exactly
  # those, since replaceVars fails on a placeholder left unfilled and on a
  # path the file doesn't use. The smoke check keeps the wrapper's name.
  passthru.tests =
    let
      zsh = finalAttrs.finalPackage;
      topics = {
        smoke = {
          description = "The wrapper execs the real zsh, and a login shell started through it is one";
          paths = { inherit zsh; };
        };
        leader = {
          description = "The leader table renders, the picker reuses its rows and runs each kind of chord with bare redraws, on an empty or a typed line, ol writes the table back only valid and lined up, and Space and Enter keep their widgets in a bare zsh";
          paths = { inherit zsh leaderAliases; };
        };
        gcloud = {
          description = "gc's secret › set reads its value silently and hands it to gcloud on stdin, and its project › set sets the project picked in fzf";
          paths = { inherit zsh leaderAliases; };
        };
        utilities = {
          description = "yp prints and copies the current directory without a newline";
          paths = { inherit zsh leaderAliases; };
        };
        nix = {
          description = "hgr and ngr list every generation but the current one, na deletes the old ones, collects the garbage and refreshes the boot menu, dr reloads direnv, and hs refreshes the home-manager flake's local inputs";
          paths = {
            inherit zsh leaderAliases;
            inherit (pkgs) jq;
          };
        };
        zoxide = {
          description = "zr lists zoxide's directories after their scores, in score order while a query filters them, and removes the ones picked in fzf";
          paths = {
            inherit zsh leaderAliases;
            inherit (pkgs) fzf zoxide;
          };
        };
        go = {
          description = "god names Go dev builds after their go.mod module, and godc clears them";
          paths = { inherit zsh; };
        };
        claude = {
          description = "A claude launch provisions its profile, drops what a session planted and runs claude under a lock it names to it, and the connection and microVM pickers, the reviews, the session tools and ca launch what was asked";
          paths = {
            inherit zsh leaderAliases claude;
            inherit (pkgs) jq;
            utilLinux = lib.getBin pkgs.util-linux;
          };
        };
        git = {
          description = "The git pickers lay out, search and open their rows, on real repos through the real fzf where it matters, and gpn creates a private GitHub repo only where it can push to it";
          paths = {
            inherit zsh leaderAliases hunkPick;
            inherit (pkgs) git fzf;
          };
        };
        fm = {
          description = "__open_file and __open_recent open what was picked, and Shift+Tab's search lists dotfiles but not .git, previews a file without its escapes and opens several picks as a quickfix list";
          paths = {
            inherit zsh fmQuery;
            inherit (pkgs) ripgrep;
          };
        };
        variables = {
          description = "Every fzf picker leaves f and y to its query, steps j/k by 1 or 5 rows with the search off and switches J/K with it, and forgit's pickers open as the git pickers do";
          paths = { inherit zsh; };
        };
        zshrc = {
          description = "The bundled .zshrc binds Shift+Space, Home/End, Shift+Tab, Tab and Alt+H, fires its empty-prompt shortcuts only at the prompt, puts the tools' completions on fpath, and starts with a cache home inherited from elsewhere";
          paths = {
            inherit zsh;
            inherit (pkgs) direnv;
          };
        };
      };
      onDisk = lib.mapAttrs' (file: _: lib.nameValuePair (lib.removeSuffix ".sh" file) null) (
        builtins.readDir ./tests
      );
      rows = lib.attrNames topics;
      bodies = lib.attrNames onDisk;
    in
    assert lib.assertMsg (rows == bodies)
      "wrappers/zsh: each tests/<topic>.sh needs a row in topics, and each row its file; without a row: ${toString (lib.subtractLists rows bodies)}; without a file: ${toString (lib.subtractLists bodies rows)}";
    lib.mapAttrs (
      topic:
      { description, paths }:
      permeance.tests.mkSmoke {
        name = if topic == "smoke" then "zsh" else "zsh-${topic}";
        inherit description;
        script = ". ${pkgs.replaceVars (./tests + "/${topic}.sh") paths}";
      }
    ) topics
    // {
      shellcheck = pkgs.testers.shellcheck {
        name = "zsh-tests";
        src = ./tests;
      };
    };
})
