{
  pkgs,
  files,
  permeance,
  git,
}:

let
  claudeStatusline = import ../packages/custom/claude-statusline { inherit pkgs; };
  claudeSessionStatus = import ../packages/custom/claude-session-status { inherit pkgs; };
  claudeDocsGuard = import ../packages/custom/claude-docs-guard { inherit pkgs; };
  gitAllowlistHook = import ../packages/custom/git-allowlist-hook { inherit pkgs; };
  # Point the shim at the wrapped git so config (excludesFile, pager, includes,
  # GIT_CONFIG_GLOBAL) applies whether git is invoked from claude or from the
  # interactive shell. The allowlist check still runs first on the same argv.
  gitShim = import ../packages/custom/git-shim {
    inherit pkgs;
    realGit = "${git}/bin/git";
  };
  firefoxMcpPkg = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };
  mobileMcpPkg = import ../packages/custom/mobile-mcp.nix { inherit pkgs; };
  awsApiMcpPkg = import ../packages/custom/aws-api-mcp.nix { inherit pkgs; };
  googleWorkspaceMcpPkg = import ../packages/custom/google-workspace-mcp.nix { inherit pkgs; };

  tools = [
    claudeStatusline
    claudeSessionStatus
    claudeDocsGuard
    gitAllowlistHook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    pkgs.rtk
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.firefox-devedition
    firefoxMcpPkg
    mobileMcpPkg
    awsApiMcpPkg
    googleWorkspaceMcpPkg
  ]
  # mcp-nixos: nixpkgs eval breaks transitively on Darwin
  # (lupa→luajit_2_0 on aarch64-darwin; arrow-cpp on x86_64-darwin, see utensils/mcp-nixos#137).
  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.mcp-nixos
  ]
  # Required by claude's built-in `/sandbox` on Linux (Seatbelt is built in on macOS).
  # Presence on PATH only enables the feature; sandbox stays off until opted into via
  # `/sandbox` or `sandbox.enabled` in settings.json.
  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.bubblewrap
    pkgs.socat
  ];

  config = files.mkConfig "claude-config" [
    ".claude/rules"
    ".claude/plugins"
    ".claude/settings.json"
    ".claude/git-allowlist.toml"

    # Renamed and installed under bin/ so it's PATH-resolvable from
    # settings.json hooks (which invoke it as `claude-format`).
    {
      source = ".claude/hooks/format.sh";
      target = "bin/claude-format";
    }
  ];

  self = pkgs.symlinkJoin {
    name = "claude-with-config";
    paths = [
      pkgs.claude-code
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "claude";
      # gitShim ships a binary named `git`. It is injected only into claude's
      # own PATH (and inherited by its subprocesses: bash, Python, Make, …),
      # not merged into $out/bin, so the user's interactive shell still sees
      # the wrapped git. Prefixed first so it wins over git-with-config within
      # claude's process tree. The shim enforces the same allowlist policy as
      # git-allowlist-hook, then exec's the real git.
      pathPrefix = [
        "${gitShim}/bin"
        "@OUT@/bin"
        "${pkgs.lib.makeBinPath tools}"
      ];
      configEnv = {
        CLAUDE_GIT_ALLOWLIST_CONFIG = ".claude/git-allowlist.toml";
      };
      staticEnv = {
        RTK_TELEMETRY_DISABLED = "1";
      };
      unsetEnv = [ "TMUX" ];
      flags = [
        "--settings"
        "$PERMEANCE_ROOT/.claude/settings.json"
        "--setting-sources"
        "user,project,local"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "claude";
      description = "Verify claude binary executes";
      script = ''
        # claude-code does not expose a config-loading probe that works in a
        # sandbox without auth/network. This test only verifies the wrapper's
        # binary executes — config-loading is exercised at runtime, not here.
        if ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "binary executes"
        else
          fail "binary failed to execute"
        fi
      '';
    };
  };
in
self
