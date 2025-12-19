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
      mkWrappers =
        pkgs:
        map (path: import path { inherit pkgs; }) [
          ./wrappers/zsh.nix
          ./wrappers/tmux.nix
          ./wrappers/bat.nix
          ./wrappers/fd.nix
          ./wrappers/ripgrep.nix
          ./wrappers/bash.nix
          ./wrappers/starship.nix
          ./wrappers/delta.nix
        ];

      mkBuildFunctions =
        system:
        let
          pkgs-24-05 = import nixpkgs-24-05 {
            inherit system;
            config.allowUnfree = true;
          };

          mkPkgs =
            configPath:
            let
              useLink = configPath != null;
              configRoot = if configPath != null then configPath else toString ./config;
            in
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = [
                (import ./overlays/lib.nix {
                  rootStr = configRoot;
                  inherit self useLink configRoot;
                })
                (final: prev: {
                  awscli2 = pkgs-24-05.awscli2;
                })
              ];
            };

          mkExtraPackages =
            pkgs:
            import ./packages { inherit pkgs system; }
            ++ mkWrappers pkgs;

          buildTerminal =
            configPath:
            let
              termPkgs = mkPkgs configPath;
            in
            import ./wrappers/alacritty.nix {
              pkgs = termPkgs;
              extraPackages = mkExtraPackages termPkgs;
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
        extraPackages = mkExtraPackages pkgs; # Bundled mode: copy config into store

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
            devExtraPackages = mkExtraPackages devPkgs;
          in
          pkgs.buildEnv {
            name = "tools-dev";
            paths = devExtraPackages;
          };
      in
      {
        # Bundled mode
        apps.default.type = "app";
        apps.default.program = "${alacritty}/bin/alacritty";
        packages.default = alacritty;
        packages.tools = tools;

        # Dev mode
        apps.dev.type = "app";
        apps.dev.program = "${alacritty-dev { }}/bin/alacritty";
        packages.dev = alacritty-dev { };
        packages.toolsDev = tools-dev { };

        devShells.default = import ./devshell.nix { inherit pkgs; };
      }
    );
}
