{ pkgs }:
pkgs.mkShell {
  packages = [
    (pkgs.writeShellScriptBin "h" ''
      printf '%-20s %s\n' \
      'dev'                 'alacritty with PERMEANCE_ROOT=./sources (live config from working tree)' \
      'bdl'                 'alacritty with bundled config (the default mode)' \
      'tools <name> [args]' 'run a CLI from the bundled tools env' \
      'smoke'               'run wrapper smoke tests' \
      'watch [cmd]'         're-run cmd on every .nix write (default: smoke)' \
      'h'                   'show this help'
    '')
    (pkgs.writeShellScriptBin "dev" ''
      root=$(git rev-parse --show-toplevel) || exit 1
      PERMEANCE_ROOT="$root/sources" nix run "$root" -- "$@"
    '')
    (pkgs.writeShellScriptBin "bdl" ''
      nix run . -- "$@"
    '')
    (pkgs.writeShellScriptBin "tools" ''
      exec nix shell .#tools --command "$@"
    '')
    (pkgs.writeShellScriptBin "smoke" ''
      nix flake check -L --keep-going -j auto "$@"
    '')
    (pkgs.writeShellScriptBin "watch" ''
      root=$(git rev-parse --show-toplevel) || exit 1
      cd "$root" || exit 1
      cmd=("$@")
      [ ''${#cmd[@]} -eq 0 ] && cmd=(nix flake check -L --keep-going -j auto)
      exec ${pkgs.watchexec}/bin/watchexec \
        --watch . --exts nix --fs-events create,remove,rename,modify \
        --restart --debounce 500ms \
        -- "''${cmd[@]}"
    '')
  ];
  shellHook = ''
    h
  '';
}
