{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.nixfmt-rfc-style
    pkgs.shfmt
    pkgs.shellharden
    pkgs.shellcheck
    pkgs.taplo
    (pkgs.writeShellScriptBin "dev" ''
      TERMINAL_CONFIG_DIR="''${TERMINAL_CONFIG_DIR:-$PWD/config}"
      export TERMINAL_CONFIG_DIR
      exec "$(nix build --impure --no-link --print-out-paths --expr '
        let
          flake = builtins.getFlake ("path:" + builtins.getEnv "PWD");
          system = builtins.currentSystem;
        in
        flake.lib.''${system}.mkTerminal {
          configPath = builtins.getEnv "TERMINAL_CONFIG_DIR";
        }
      ')/bin/alacritty" "$@"
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
