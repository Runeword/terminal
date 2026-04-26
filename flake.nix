{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixpkgs-24-05.url = "github:NixOS/nixpkgs/nixos-24.05";
  inputs.nixpkgs-25-11.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.claude = {
    url = "github:Runeword/claude";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.lefthook = {
    url = "github:Runeword/lefthook";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # inputs.hello-flake.url = "github:sbellem/hello-flake";

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-24-05,
      nixpkgs-25-11,
      flake-utils,
      claude,
      lefthook,
      ...
    }@inputs:
    let
      mkWrappers = pkgs: configPath: import ./wrappers { inherit pkgs configPath; };

      mkTools =
        pkgs: configPath:
        import ./packages { inherit pkgs configPath; } ++ builtins.attrValues (mkWrappers pkgs configPath);

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
          overlays = [ ];
        };

        pkgs-25-11 = import nixpkgs-25-11 {
          inherit system;
          config.allowUnfree = true;
          overlays = [ ];
        };

        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = import ./overlays { inherit pkgs-24-05 pkgs-25-11; };
        };

        configPath = toString ./config;
        terminal = mkTerminal pkgs configPath;
      in
      {
        packages.default = terminal;
        packages.tools =
          let
            env = pkgs.buildEnv {
              name = "tools-env";
              paths = mkTools pkgs configPath;
            };
          in
          pkgs.writeShellScriptBin "tools" ''
            exec ${env}/bin/"$1" "''${@:2}"
          '';

        apps.default = {
          type = "app";
          program = "${terminal}/bin/alacritty";
        };
        apps.dev = {
          type = "app";
          program = "${mkTerminal pkgs (builtins.getEnv "TERMINAL_CONFIG_DIR")}/bin/alacritty";
        };

        lib.mkTerminal =
          {
            configPath ? toString ./config,
          }:
          mkTerminal pkgs configPath;
        lib.mkTools =
          {
            configPath ? toString ./config,
          }:
          pkgs.buildEnv {
            name = "tools";
            paths = mkTools pkgs configPath;
          };

        devShells.default = pkgs.mkShell {
          inputsFrom = [
            (import ./devshells/terminal.nix { inherit pkgs; })
            (import ./devshells/languages.nix { inherit pkgs; })
            claude.devShells.${system}.ast-grep
            (import ./devshells/lefthook.nix { inherit pkgs lefthook; })
          ];
        };

        checks =
          pkgs.lib.mapAttrs'
            (name: drv: {
              name = "smoke-${name}";
              value = drv;
            })
            (
              import ./checks/smoke.nix {
                inherit pkgs;
                wrappers = mkWrappers pkgs configPath;
              }
            );
      }
    )
    // {
      homeModules.default = import ./modules/terminal.nix {
        mkSystemBuild = system: self.lib.${system};
      };
    };
}
