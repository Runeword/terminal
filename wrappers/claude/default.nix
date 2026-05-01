{
  pkgs,
  files,
  tests,
}:

let
  claudeStatusline = import ../../packages/custom/claude-statusline { inherit pkgs; };
  firefoxMcpPkg = import ../../packages/custom/firefox-mcp.nix { inherit pkgs; };
  mobileMcpPkg = import ../../packages/custom/mobile-mcp.nix { inherit pkgs; };

  tools = [
    claudeStatusline
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    # Plugin binaries — referenced by bare name from config/claude/plugins/*.mcp.json
    pkgs.mcp-nixos
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.firefox-devedition
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
    {
      source = "claude/rules";
      target = "rules";
    }
    {
      source = "claude/plugins";
      target = "plugins";
    }
    {
      source = "claude/settings.json";
      target = "settings.json";
    }
    {
      source = "claude/hooks/format.sh";
      target = "bin/claude-format";
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
      wrapProgram $out/bin/claude \
        --prefix PATH : "$out/bin:${pkgs.lib.makeBinPath tools}" \
        --add-flags "--settings $out/settings.json --setting-sources project,local" \
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
