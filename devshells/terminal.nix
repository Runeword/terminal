{ pkgs }:
let
  # sources/ paths a wrapper compiles at build time (bat's theme cache), which
  # PERMEANCE_ROOT can't redirect: `build`, and so `dev`, rebuilds when they
  # change.
  bakedSources = [ "sources/.config/bat/themes" ];

  # Opens the window in the environment from before direnv loaded this devshell.
  # A window that inherits direnv's state reverts PATH to that environment's on
  # its first cd out of the repo, dropping the tools of the build it runs.
  withoutDirenv = "${pkgs.direnv}/bin/direnv exec /";

  # The build `dev` runs, which `build` makes and `run` opens. Evaluating the
  # terminal takes ~8 s, and any edit to a tracked file invalidates nix's eval
  # cache. So the build is kept as an out-link (a GC root), with the key of
  # what nix built it from: everything outside sources/, which PERMEANCE_ROOT
  # replaces at run time, plus bakedSources. `current` says whether the build
  # is the tree's.
  devState = ''
    root=$(git rev-parse --show-toplevel) || exit 1
    cache=$root/.direnv/dev
    key=$(cd "$root" && {
      git ls-files -z -- ':!sources'
      git ls-files -z -- ${pkgs.lib.escapeShellArgs bakedSources}
    } | xargs -0 sha256sum 2>/dev/null | sha256sum)
    current() { [ -e "$cache/terminal" ] && [ "$(cat "$cache/key" 2>/dev/null)" = "$key" ]; }
  '';
  # Builds the terminal again when the build isn't the tree's, saying so as
  # helper `name`.
  devBuild = name: ''
    if ! current; then
      echo "${name}: building the terminal (a file outside sources/ changed, or no build yet)" >&2
      mkdir -p "$cache"
      nix build -L "$root" --out-link "$cache/terminal" || exit 1
      printf '%s\n' "$key" >"$cache/key"
    fi
  '';
  # Opens the build's window, with the live config of the working tree.
  devRun = ''
    PERMEANCE_ROOT="$root/sources" exec ${withoutDirenv} "$cache/terminal/bin/alacritty" "$@"
  '';

  helpers = [
    {
      name = "dev";
      doc = "build, then run: alacritty with PERMEANCE_ROOT=./sources (live config)";
      inherit bakedSources;
      text = devState + devBuild "dev" + devRun;
    }
    {
      name = "build";
      doc = "build what dev runs, when a file outside sources/ changed";
      text =
        devState
        + ''
          current && echo "build: up to date" >&2
        ''
        + devBuild "build";
    }
    {
      name = "run";
      doc = "run dev's last build without building (warns when it is stale)";
      text =
        devState
        + ''
          if [ ! -e "$cache/terminal" ]; then
            echo "run: no build yet: build (or dev) makes one" >&2
            exit 1
          fi
          current || echo "run: this build predates a change outside sources/: build (or dev) updates it" >&2
        ''
        + devRun;
    }
    {
      name = "bdl";
      doc = "alacritty with bundled config (the default mode)";
      text = ''
        exec ${withoutDirenv} nix run . -- "$@"
      '';
    }
    {
      name = "tools";
      usage = "tools <name> [args]";
      doc = "run a CLI from the bundled tools env";
      text = ''
        exec nix shell .#tools --command "$@"
      '';
    }
    {
      name = "smoke";
      doc = "run wrapper smoke tests";
      text = ''
        nix flake check -L --keep-going -j auto "$@"
      '';
    }
    {
      name = "watch";
      usage = "watch [cmd]";
      doc = "re-run cmd on every .nix write (default: smoke)";
      text = ''
        root=$(git rev-parse --show-toplevel) || exit 1
        cd "$root" || exit 1
        cmd=("$@")
        [ ''${#cmd[@]} -eq 0 ] && cmd=(nix flake check -L --keep-going -j auto)
        exec ${pkgs.watchexec}/bin/watchexec \
          --watch . --exts nix --fs-events create,remove,rename,modify \
          --restart --debounce 500ms \
          -- "''${cmd[@]}"
      '';
    }
  ];
in
pkgs.mkShell {
  packages = map (h: pkgs.writeShellScriptBin h.name h.text) helpers;
  passthru.helpers = helpers;
}
