{
  description = "Alacritty with configuration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  inputs.flake-utils.url = "github:numtide/flake-utils";

  inputs.lefthook.url = "github:Runeword/lefthook";
  inputs.lefthook.inputs.nixpkgs.follows = "nixpkgs";

  # The two private inputs are fetched over ssh, so nix logs in through the
  # ssh agent, from a claude-sandbox session too; ci.yml rewrites the address
  # to https with a GitHub App token. The ref is spelled out because the
  # session's git shim refuses the ls-remote nix would use to find the default
  # branch, and shallow=1 skips the history, which a github: input never had.
  inputs.permeance.url = "git+ssh://git@github.com/Runeword/permeance?ref=main&shallow=1";
  inputs.permeance.inputs.nixpkgs.follows = "nixpkgs";

  inputs.claude-sandbox.url = "git+ssh://git@github.com/Runeword/claude-sandbox?ref=main&shallow=1";
  inputs.claude-sandbox.inputs.nixpkgs.follows = "nixpkgs";

  # The claude wrapper (wrappers/claude.nix builds it with this terminal's git).
  # Public, so no token; every input it shares with this flake follows this
  # one's, so claude's tools and launchers are the terminal's builds.
  inputs.claude.url = "github:Runeword/claude";
  inputs.claude.inputs.nixpkgs.follows = "nixpkgs";
  inputs.claude.inputs.lefthook.follows = "lefthook";
  inputs.claude.inputs.permeance.follows = "permeance";
  inputs.claude.inputs.claude-sandbox.follows = "claude-sandbox";
  inputs.claude.inputs.nix-index-database.follows = "nix-index-database";

  # comma's prebuilt index, on claude's PATH. Only the claude flake uses it:
  # an input here, which that flake's follows, so this repository's input
  # updates keep the index fresh.
  inputs.nix-index-database.url = "github:nix-community/nix-index-database";
  inputs.nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

  # inputs.hello-flake.url = "github:sbellem/hello-flake";

  outputs =
    inputs@{ self, ... }:
    let
      mkPermeance = pkgs: inputs.permeance.lib pkgs;

      # The claude sandbox's launchers and helpers, for pkgs' system.
      mkClaudeSandbox = pkgs: inputs.claude-sandbox.packages.${pkgs.stdenv.hostPlatform.system};

      mkWrappers =
        pkgs: configPath:
        import ./wrappers {
          inherit pkgs configPath;
          inherit (inputs.claude.lib) mkClaude;
          permeance = mkPermeance pkgs;
          claudeSandbox = mkClaudeSandbox pkgs;
        };

      mkTools =
        pkgs: wrappers:
        import ./packages {
          inherit pkgs;
          claudeSandbox = mkClaudeSandbox pkgs;
          claudePackages = inputs.claude.packages.${pkgs.stdenv.hostPlatform.system};
        }
        ++ builtins.attrValues wrappers;

      mkTerminal =
        pkgs: configPath: tools:
        import ./wrappers/alacritty.nix {
          inherit pkgs configPath tools;
          permeance = mkPermeance pkgs;
        };

      mkPkgs =
        system:
        import inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = import ./overlays;
        };
    in
    inputs.flake-utils.lib.eachSystem
      # nixpkgs-unstable (26.11) dropped x86_64-darwin support entirely, so it
      # can no longer be imported for that system — every output would throw at
      # evaluation. Expose the remaining default systems only.
      (builtins.filter (s: s != "x86_64-darwin") inputs.flake-utils.lib.defaultSystems)
      (
        system:
        let
          pkgs = mkPkgs system;

          configPath = ./sources;
          wrappers = mkWrappers pkgs configPath;
          tools = mkTools pkgs wrappers;
          terminal = mkTerminal pkgs configPath tools;

          devShell = import ./devshells {
            inherit pkgs;
            inherit (inputs) lefthook;
          };

          unitTests = import ./lib/tests-unit.nix {
            inherit (pkgs) lib;
            inherit wrappers terminal;
            devShellHelpers = devShell.helpers;
          };
        in
        {
          packages.default = terminal;
          packages.tools = pkgs.buildEnv {
            name = "tools";
            paths = tools;
            # Restrict to /bin so wrappers that share config files (e.g. fd and
            # ripgrep both ship .config/ignore) don't conflict in the merged env.
            pathsToLink = [ "/bin" ];
          };

          apps.default = {
            type = "app";
            program = "${terminal}/bin/alacritty";
            meta.description = "Alacritty terminal (set $PERMEANCE_ROOT to a sources tree for live config)";
          };

          devShells.default = devShell;

          # Every wrapper test is a check: smoke under the wrapper's own name,
          # any other as <wrapper>-<test> (zsh's topics, wrappers/zsh/default.nix).
          checks =
            pkgs.lib.concatMapAttrs (
              wrapper: drv:
              pkgs.lib.mapAttrs' (
                test: check:
                pkgs.lib.nameValuePair (if test == "smoke" then wrapper else "${wrapper}-${test}") check
              ) drv.passthru.tests
            ) wrappers
            // {
              alacritty = terminal.passthru.tests.smoke;
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
          configPath ? ./sources,
        }:
        let
          pkgs = mkPkgs system;
        in
        mkTerminal pkgs configPath (mkTools pkgs (mkWrappers pkgs configPath));

      lib.mkTools =
        {
          system,
          configPath ? ./sources,
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
