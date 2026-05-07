{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixpkgs-24-05.url = "github:NixOS/nixpkgs/nixos-24.05";
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
      flake-utils,
      claude,
      lefthook,
      ...
    }@inputs:
    let
      mkWrappers = pkgs: configPath: import ./wrappers { inherit pkgs configPath; };

      mkTools =
        pkgs: configPath: wrappers:
        import ./packages { inherit pkgs configPath; } ++ builtins.attrValues wrappers;

      mkTerminal =
        pkgs: configPath: tools:
        import ./wrappers/alacritty.nix {
          inherit pkgs configPath tools;
        };

      mkPkgs =
        system:
        let
          pkgs-24-05 = import nixpkgs-24-05 {
            inherit system;
            config.allowUnfree = true;
            overlays = [ ];
          };
        in
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = import ./overlays { inherit pkgs-24-05; };
        };
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = mkPkgs system;

        configPath = ./config;
        wrappers = mkWrappers pkgs configPath;
        tools = mkTools pkgs configPath wrappers;
        terminal = mkTerminal pkgs configPath tools;
      in
      {
        packages.default = terminal;
        packages.firefox-mcp = import ./packages/custom/firefox-mcp.nix { inherit pkgs; };
        packages.mobile-mcp = import ./packages/custom/mobile-mcp.nix { inherit pkgs; };
        packages.tools = pkgs.buildEnv {
          name = "tools";
          paths = tools;
          # Restrict to /bin so wrappers that share config files (e.g. fd and
          # ripgrep both ship .config/ignore) don't conflict in the merged env.
          pathsToLink = [ "/bin" ];
        };

        apps =
          let
            devConfigPath = builtins.getEnv "TERMINAL_CONFIG_DIR";
          in
          {
            default = {
              type = "app";
              program = "${terminal}/bin/alacritty";
              meta.description = "Alacritty terminal with bundled config";
            };
          }
          # apps.dev requires TERMINAL_CONFIG_DIR; omitted in pure mode (getEnv → "")
          # so `nix flake check` stays clean.
          // pkgs.lib.optionalAttrs (devConfigPath != "") {
            dev =
              let
                devWrappers = mkWrappers pkgs devConfigPath;
                devTools = mkTools pkgs devConfigPath devWrappers;
              in
              {
                type = "app";
                program = "${mkTerminal pkgs devConfigPath devTools}/bin/alacritty";
              };
          };

        devShells.default = pkgs.mkShell {
          inputsFrom = [
            (import ./devshells/terminal.nix { inherit pkgs; })
            (import ./devshells/languages.nix { inherit pkgs; })
            claude.devShells.${system}.ast-grep
            (import ./devshells/lefthook.nix { inherit pkgs lefthook; })
          ];
        };

        checks = pkgs.lib.mapAttrs (_: drv: drv.passthru.tests.smoke) wrappers;
      }
    )
    // {
      lib.mkTerminal =
        {
          system,
          configPath ? ./config,
        }:
        let
          pkgs = mkPkgs system;
        in
        mkTerminal pkgs configPath (mkTools pkgs configPath (mkWrappers pkgs configPath));

      lib.mkTools =
        {
          system,
          configPath ? ./config,
        }:
        let
          pkgs = mkPkgs system;
        in
        pkgs.buildEnv {
          name = "tools";
          paths = mkTools pkgs configPath (mkWrappers pkgs configPath);
          pathsToLink = [ "/bin" ];
        };

      homeModules.default = import ./modules/terminal.nix {
        flake = self;
      };
    };
}
