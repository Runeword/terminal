{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    (pkgs.writeShellScriptBin "h" ''
      echo "'dev' run alacritty in development mode"
      echo "'bdl' run alacritty in bundled mode"
      echo "'tools' <name> run a binary from the tools package"
      echo "'smoke' run wrapper smoke tests"
      echo "'h' for help"
    '')
    (pkgs.writeShellScriptBin "dev" ''
      TERMINAL_CONFIG_DIR="$PWD/config" nix run .#dev --impure -- "$@"
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
