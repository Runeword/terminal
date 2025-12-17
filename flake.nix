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
    let
      mkBuildFunctions =
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
                  rootStr = if configPath != null then configPath else toString ./config;
                  inherit self;
                })
                (final: prev: {
                  awscli2 = pkgs-24-05.awscli2;
                })
              ];
            };

          mkExtraPackages =
            pkgs: useLink: configRoot:
            let
              mkConfig = pkgs.lib.mkConfig useLink configRoot;
            in
            (import ./packages/commons.nix { inherit pkgs; })
            ++ (
              if pkgs.stdenv.isDarwin then
                (import ./packages/darwin.nix { inherit pkgs system; })
              else
                (import ./packages/linux.nix { inherit pkgs system; })
            )
            ++ [
              (import ./wrappers/zsh.nix { inherit pkgs mkConfig; })
              (import ./wrappers/tmux.nix { inherit pkgs mkConfig; })
              (import ./wrappers/bat.nix { inherit pkgs mkConfig; })
              (import ./wrappers/fd.nix { inherit pkgs mkConfig; })
              (import ./wrappers/ripgrep.nix { inherit pkgs mkConfig; })
              (import ./wrappers/bash.nix { inherit pkgs mkConfig; })
              (import ./wrappers/starship.nix { inherit pkgs mkConfig; })
              (import ./wrappers/delta.nix { inherit pkgs mkConfig; })
            ];

          buildTerminal =
            configPath:
            let
              termPkgs = mkPkgs configPath;
              useLink = configPath != null;
              configRoot = if configPath != null then configPath else ./config;
            in
            import ./wrappers/alacritty.nix {
              pkgs = termPkgs;
              extraPackages = mkExtraPackages termPkgs useLink configRoot;
              mkConfig = termPkgs.lib.mkConfig useLink configRoot;
            };
        in
        {
          inherit
            mkPkgs
            mkExtraPackages
            buildTerminal
            ;
        };
    in
    {
      homeManagerModules.default = import ./modules/terminal.nix { inherit mkBuildFunctions; };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        build = mkBuildFunctions system;
        inherit (build) mkPkgs mkExtraPackages;

        pkgs = mkPkgs null;
        extraPackages = mkExtraPackages pkgs false ./config; # Bundled mode: copy config into store

        alacritty = build.buildTerminal null;

        alacritty-dev =
          {
            configPath ? builtins.getEnv "TERMINAL_CONFIG_DIR",
          }:
          build.buildTerminal configPath;

        tools = pkgs.buildEnv {
          name = "tools";
          paths = extraPackages;
        };

        tools-dev =
          {
            configPath ? builtins.getEnv "TERMINAL_CONFIG_DIR",
          }:
          let
            devPkgs = mkPkgs configPath;
            devExtraPackages = mkExtraPackages devPkgs true configPath;
          in
          pkgs.buildEnv {
            name = "tools-dev";
            paths = devExtraPackages;
          };
      in
      {
        packages.tools = tools;
        packages.toolsDev = tools-dev { };

        # Bundled mode
        apps.default.type = "app";
        apps.default.program = "${alacritty}/bin/alacritty";
        packages.default = alacritty;

        # Dev mode
        apps.dev.type = "app";
        apps.dev.program = "${alacritty-dev { }}/bin/alacritty";
        packages.dev = alacritty-dev { };

        devShells.default = import ./devshell.nix { inherit pkgs; };
      }
    );
}
