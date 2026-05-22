{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-24-05.url = "github:NixOS/nixpkgs/nixpkgs-24.05-darwin";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  inputs.claude.url = "github:Runeword/claude";
  inputs.claude.inputs.nixpkgs.follows = "nixpkgs";

  inputs.lefthook.url = "github:Runeword/lefthook";
  inputs.lefthook.inputs.nixpkgs.follows = "nixpkgs";

  # inputs.hello-flake.url = "github:sbellem/hello-flake";

  outputs =
    inputs@{ self, ... }:
    let
      mkWrappers = pkgs: configPath: import ./wrappers { inherit pkgs configPath; };

      mkTools = pkgs: wrappers: import ./packages { inherit pkgs; } ++ builtins.attrValues wrappers;

      mkTerminal =
        pkgs: configPath: tools:
        import ./wrappers/alacritty.nix {
          inherit pkgs configPath tools;
        };

      mkPkgs =
        system:
        let
          pkgs-24-05 = import inputs.nixpkgs-24-05 {
            inherit system;
            config.allowUnfree = true;
            overlays = [ ];
          };
        in
        import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = import ./overlays { inherit pkgs-24-05; };
        };
    in
    inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = mkPkgs system;

        configPath = ./config;
        wrappers = mkWrappers pkgs configPath;
        tools = mkTools pkgs wrappers;
        terminal = mkTerminal pkgs configPath tools;

        unitTests = import ./lib/tests-unit.nix {
          inherit (pkgs) lib;
          inherit wrappers;
        };
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
                devTools = mkTools pkgs devWrappers;
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
            (import ./devshells/infra.nix { inherit pkgs; })
            inputs.claude.devShells.${system}.ast-grep
            (import ./devshells/lefthook.nix {
              inherit pkgs;
              inherit (inputs) lefthook;
            })
          ];
        };

        checks = (pkgs.lib.mapAttrs (_: drv: drv.passthru.tests.smoke) wrappers) // {
          unit-tests =
            let
              failures = pkgs.lib.runTests unitTests;
            in
            pkgs.runCommand "unit-tests"
              {
                passthru.failures = failures;
              }
              (
                if failures == [ ] then
                  "touch $out"
                else
                  ''
                    echo ${pkgs.lib.escapeShellArg (builtins.toJSON failures)} >&2
                    exit 1
                  ''
              );
        };
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
        mkTerminal pkgs configPath (mkTools pkgs (mkWrappers pkgs configPath));

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
          paths = mkTools pkgs (mkWrappers pkgs configPath);
          pathsToLink = [ "/bin" ];
        };

      homeModules.default = import ./modules/terminal.nix {
        flake = self;
      };
    };
}
