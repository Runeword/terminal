{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.nix-update
    (pkgs.writeShellScriptBin "h" ''
      echo "type 'dev' to run alacritty in development mode"
      echo "type 'bdl' to run alacritty in bundled mode"
      echo "type 'tools' <name> to run a binary from the tools package"
      echo "type 'smoke' to run wrapper smoke tests"
      echo "type 'h' for help"
    '')
    (pkgs.writeShellScriptBin "dev" ''
      TERMINAL_CONFIG_DIR="$PWD/config" nix run .#dev --impure -- "$@"
    '')
    (pkgs.writeShellScriptBin "bdl" ''
      nix run . -- "$@"
    '')
    (pkgs.writeShellScriptBin "tools" ''
      nix run .#tools -- "$@"
    '')
    (pkgs.writeShellScriptBin "smoke" ''
      nix flake check -L --keep-going -j auto "$@"
    '')
  ];
  shellHook = ''
    h
  '';
}
