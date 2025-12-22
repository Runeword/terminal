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
      mkTerminal =
        pkgs:
        {
          configPath ? toString ./config,
        }:
        import ./wrappers/alacritty.nix {
          inherit pkgs configPath;
          tools =
            import ./packages { inherit pkgs configPath; } ++ import ./wrappers { inherit pkgs configPath; };
        };

      mkTools =
        pkgs:
        {
          configPath ? toString ./config,
        }:
        pkgs.buildEnv {
          name = "tools";
          paths =
            import ./packages { inherit pkgs configPath; } ++ import ./wrappers { inherit pkgs configPath; };
        };

      mkSystemBuild =
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
        in
        {
          inherit pkgs;
          mkTerminal = mkTerminal pkgs;
          mkTools = mkTools pkgs;
        };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        build = mkSystemBuild system;
      in
      {
        # Bundled mode
        apps.default.type = "app";
        apps.default.program = "${build.mkTerminal { }}/bin/alacritty";
        packages.default = build.mkTerminal { };
        packages.tools = build.mkTools { };

        # Dev mode
        apps.dev.type = "app";
        apps.dev.program = "${
          build.mkTerminal { configPath = builtins.getEnv "TERMINAL_CONFIG_DIR"; }
        }/bin/alacritty";
        packages.dev = build.mkTerminal { configPath = builtins.getEnv "TERMINAL_CONFIG_DIR"; };
        packages.devTools = build.mkTools { configPath = builtins.getEnv "TERMINAL_CONFIG_DIR"; };

        devShells.default = import ./devshell.nix { inherit (build) pkgs; };
      }
    )
    // {
      homeManagerModules.default = import ./modules/terminal.nix { inherit mkSystemBuild; };
    };
}
