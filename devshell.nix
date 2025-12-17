{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.nixfmt-rfc-style
    pkgs.shfmt
    pkgs.shellharden
    pkgs.shellcheck
    pkgs.taplo
    (pkgs.writeShellScriptBin "dev" ''
      TERMINAL_CONFIG_DIR="$PWD/config" nix run .#dev --impure "$@"
    '')
    (pkgs.writeShellScriptBin "h" ''
      echo "type 'dev' to run alacritty in development mode"
      echo "type 'bdl' to run alacritty in bundled mode"
      echo "type 'h' for help"
    '')
    (pkgs.writeShellScriptBin "bdl" ''
      nix run . "$@"
    '')
  ];
  shellHook = ''
    h
  '';
}
