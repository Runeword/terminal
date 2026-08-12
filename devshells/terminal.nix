{ pkgs }:
let
  helpers = [
    {
      name = "dev";
      doc = "alacritty with PERMEANCE_ROOT=./sources (live config from working tree)";
      text = ''
        root=$(git rev-parse --show-toplevel) || exit 1
        PERMEANCE_ROOT="$root/sources" nix run "$root" -- "$@"
      '';
    }
    {
      name = "bdl";
      doc = "alacritty with bundled config (the default mode)";
      text = ''
        nix run . -- "$@"
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
