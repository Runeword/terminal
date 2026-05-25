{
  pkgs,
  files,
  tests,
  git,
}:

let
  claudeStatusline = import ../packages/custom/claude-statusline { inherit pkgs; };
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
    gitAllowlistHook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    pkgs.rtk
    # Plugin binaries — referenced by bare name from config/claude/plugins/*.mcp.json
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.firefox-devedition
    firefoxMcpPkg
    mobileMcpPkg
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

    # Renamed and installed under bin/ so they're PATH-resolvable from
    # settings.json hooks (which invoke them as `claude-format` / `claude-docs-guard`).
    {
      source = ".claude/hooks/format.sh";
      target = "bin/claude-format";
    }
    {
      source = ".claude/hooks/docs-guard.sh";
      target = "bin/claude-docs-guard";
    }
  ];

  self = pkgs.symlinkJoin {
    name = "claude-with-config";
    paths = [
      pkgs.claude-code
      config
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      # gitShim ships a binary named `git`. It is injected only into claude's
      # own PATH (and inherited by its subprocesses: bash, Python, Make, …),
      # not merged into $out/bin, so the user's interactive shell still sees
      # the wrapped git. Prefixed first so it wins over git-with-config within
      # claude's process tree. The shim enforces the same allowlist policy as
      # git-allowlist-hook, then exec's the real git.
      wrapProgram $out/bin/claude \
        --prefix PATH : "${gitShim}/bin:$out/bin:${pkgs.lib.makeBinPath tools}" \
        --add-flags "--settings $out/.claude/settings.json --setting-sources project,local --add-dir $out" \
        --set-default CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD 1 \
        --set CLAUDE_GIT_ALLOWLIST_CONFIG $out/.claude/git-allowlist.toml \
        --set RTK_TELEMETRY_DISABLED 1 \
        --unset TMUX
    '';
    passthru.tests.smoke = tests.smoke {
      name = "claude";
      description = "Verify claude binary executes (no behavioral config probe available without auth/network)";
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
