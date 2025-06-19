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
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [
            (import ./overlays/lib.nix {
              rootStr = builtins.getEnv "TERM_CONFIG_DIR";
              inherit self;
            })
          ];
        };

        extraPackages =
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

        alacritty = import ./packages/wrappers/alacritty.nix {
          inherit pkgs extraPackages;
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
