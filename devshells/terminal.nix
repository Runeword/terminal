{ pkgs }:
pkgs.mkShell {
  packages = [
    (pkgs.writeShellScriptBin "h" ''
      printf '%-20s %s\n' \
      'dev'                 'alacritty with configs symlinked from ./sources (edit live, no rebuild)' \
      'bdl'                 'alacritty with configs copied into the nix store (requires rebuild)' \
      'tools <name> [args]' 'run a CLI from the bundled tools env' \
      'smoke'               'run wrapper smoke tests' \
      'h'                   'show this help'
    '')
    (pkgs.writeShellScriptBin "dev" ''
      root=$(git rev-parse --show-toplevel) || exit 1
      TERMINAL_CONFIG_DIR="$root/sources" nix run "$root#dev" --impure -- "$@"
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
  ];
  shellHook = ''
    h
  '';
}
