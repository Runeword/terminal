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
  claudeContext = import ../packages/custom/claude-context { inherit pkgs; };
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

  tools = [
    claudeStatusline
    claudeSessionStatus
    claudeDocsGuard
    claudeContext
    gitAllowlistHook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    pkgs.rtk
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.gopls
    pkgs.bash-language-server
    pkgs.yaml-language-server
    pkgs.terraform-ls
    pkgs.marksman
    pkgs.vscode-langservers-extracted
    pkgs.shellcheck
    pkgs.firefox-devedition
    # Runtimes for MCP servers launched from a plugin .mcp.json rather than being
    # Nix-packaged: nodejs/npx for figma-mcp; uv/uvx + python for the pure-Python
    # servers (nix-mcp, aws-api-mcp, google-workspace-mcp). uvx fetches the pinned
    # server from PyPI at run time (cached under $CLAUDE_CONFIG_DIR); python312 with
    # UV_PYTHON_PREFERENCE=only-system avoids a managed-Python download and gives
    # broad wheel coverage. firefox-mcp/mobile-mcp stay Nix-packaged because they
    # also need sidecar binaries on PATH (geckodriver, adb).
    pkgs.nodejs
    pkgs.uv
    pkgs.python312
    firefoxMcpPkg
    mobileMcpPkg
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
