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
      mkTools =
        pkgs: configPath:
        import ./packages { inherit pkgs configPath; }
        ++ import ./wrappers { inherit pkgs configPath; };

      mkTerminal =
        pkgs: configPath:
        import ./wrappers/alacritty.nix {
          inherit pkgs configPath;
          tools = mkTools pkgs configPath;
        };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs-24-05 = import nixpkgs-24-05 {
          inherit system;
          config.allowUnfree = true;
        };

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = import ./overlays { inherit pkgs-24-05; };
        };

        configPath = toString ./config;
        devConfigPath = builtins.getEnv "TERMINAL_CONFIG_DIR";

        bundled = mkTerminal pkgs configPath;
        dev = mkTerminal pkgs devConfigPath;
      in
      {
        packages.default = bundled;
        packages.dev = dev;
        packages.tools = pkgs.buildEnv { name = "tools"; paths = mkTools pkgs configPath; };
        packages.devTools = pkgs.buildEnv { name = "tools"; paths = mkTools pkgs devConfigPath; };

        apps.default = { type = "app"; program = "${bundled}/bin/alacritty"; };
        apps.dev = { type = "app"; program = "${dev}/bin/alacritty"; };

        devShells.default = import ./devshell.nix { inherit pkgs; };
      }
    )
    // {
      homeManagerModules.default = import ./modules/terminal.nix {
        mkSystemBuild = system:
          let
            pkgs-24-05 = import nixpkgs-24-05 {
              inherit system;
              config.allowUnfree = true;
            };
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = import ./overlays { inherit pkgs-24-05; };
            };
          in
          {
            inherit pkgs;
            mkTerminal = { configPath ? toString ./config }: mkTerminal pkgs configPath;
            mkTools = { configPath ? toString ./config }: pkgs.buildEnv {
              name = "tools";
              paths = mkTools pkgs configPath;
            };
          };
      };
    };
}
