{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
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
            ];
          };

        mkExtraPackages =
          pkgs:
          (import ./packages/commons.nix { inherit pkgs; })
          ++ (
            if pkgs.stdenv.isDarwin then
              (import ./packages/darwin.nix { inherit pkgs system; })
            else
              (import ./packages/linux.nix { inherit pkgs system; })
          )
          ++ [
            (import ./packages/wrappers/zsh.nix { inherit pkgs; })
            (import ./packages/wrappers/tmux.nix { inherit pkgs; })
            # (import ./packages/wrappers/bash.nix { inherit pkgs; })
          ];

        pkgs = mkPkgs null;
        extraPackages = mkExtraPackages pkgs;

        alacritty = import ./packages/wrappers/alacritty.nix {
          inherit pkgs extraPackages;
        };

        alacritty-dev =
          {
            configPath ? builtins.getEnv "TERM_CONFIG_DIR",
          }:
          let
            devPkgs = mkPkgs configPath;
            devExtraPackages = mkExtraPackages devPkgs;
          in
          import ./packages/wrappers/alacritty.nix {
            pkgs = devPkgs;
            extraPackages = devExtraPackages;
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
