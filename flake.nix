{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixpkgs-24-05.url = "github:NixOS/nixpkgs/nixos-24.05";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-24-05,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs-24-05 = import nixpkgs-24-05 {
          inherit system;
          config.allowUnfree = true;
        };

        mkPkgs =
          configPath:
          import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [
              (import ./overlays/lib.nix {
                rootStr = if configPath != null then configPath else toString ./.;
                inherit self;
              })
              (final: prev: {
                awscli2 = pkgs-24-05.awscli2;
              })
            ];
          };

        mkExtraPackages =
          pkgs: useLink:
          (import ./packages/commons.nix { inherit pkgs; })
          ++ (
            if pkgs.stdenv.isDarwin then
              (import ./packages/darwin.nix { inherit pkgs system; })
            else
              (import ./packages/linux.nix { inherit pkgs system; })
          )
          ++ [
            (import ./wrappers/zsh.nix { inherit pkgs useLink; })
            (import ./wrappers/tmux.nix { inherit pkgs useLink; })
            (import ./wrappers/bat.nix { inherit pkgs useLink; })
            (import ./wrappers/fd.nix { inherit pkgs useLink; })
            (import ./wrappers/ripgrep.nix { inherit pkgs useLink; })
            (import ./wrappers/bash.nix { inherit pkgs useLink; })
            (import ./wrappers/starship.nix { inherit pkgs useLink; })
            (import ./wrappers/delta.nix { inherit pkgs useLink; })
          ];

        pkgs = mkPkgs null;
        extraPackages = mkExtraPackages pkgs false; # Bundled mode: copy config into store

        alacritty = import ./wrappers/alacritty.nix {
          inherit pkgs extraPackages;
          useLink = false; # Bundled mode: copy config into store
        };

        alacritty-dev =
          {
            configPath ? builtins.getEnv "TERM_CONFIG_DIR",
          }:
          import ./wrappers/alacritty.nix {
            pkgs = mkPkgs configPath;
            extraPackages = mkExtraPackages (mkPkgs configPath) true; # Dev mode: symlink to external config
            useLink = true; # Dev mode: symlink to external config
          };

        # zsh = pkgs.symlinkJoin {
        #   name = "zsh";
        #   paths = extraPackages;
        # };

      in
      {
        apps.default.type = "app";
        apps.default.program = "${alacritty}/bin/alacritty";
        packages.default = alacritty;

        # Dev mode
        apps.dev.type = "app";
        apps.dev.program = "${alacritty-dev { }}/bin/alacritty";
        packages.dev.default = alacritty-dev { };
        packages.dev.options = alacritty-dev;

        devShells.default = pkgs.mkShell {
          buildInputs = [
            (pkgs.writeShellScriptBin "dev" ''
              TERM_CONFIG_DIR="$PWD/config" nix run .#dev --impure "$@"
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
        };

        # # Dev mode
        # apps.dev.type = "app";
        # apps.dev.program = "${alacritty-dev { }}/bin/nvim";
        # packages.dev.default = alacritty-dev { };
        # packages.dev.options = alacritty-dev;

        # apps.zsh.type = "app";
        # apps.zsh.program = "${zsh}/bin/zsh";
        # packages.zsh = zsh;
      }
    );
}
