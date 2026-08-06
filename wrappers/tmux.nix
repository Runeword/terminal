{
  pkgs,
  files,
  permeance,
  zsh,
}:

let
  # Alt+Tab session switcher, bound in tmux.conf. Reached by absolute store
  # path rather than PATH: the tmux server inherits its environment from
  # whatever launched it, so a bare name would resolve only sometimes.
  tmuxSessions = import ../packages/custom/tmux-sessions { inherit pkgs; };

  config = files.mkConfig "tmux-config" [
    ".config/tmux/tmux.conf"
    ".config/tmux/scripts/toggle-pane.sh"
    # Bound in tmux.conf (claude-sessions.sh on M-s; watch-build.sh on a
    # currently-commented M-b) — bundle both so the bindings resolve in
    # bundled mode, not just under $PERMEANCE_ROOT.
    ".config/tmux/scripts/claude-sessions.sh"
    ".config/tmux/scripts/watch-build.sh"
    ".config/shell/functions/tmux.sh"
    # tmux-resurrect plugin tree, supplied by nixpkgs instead of vendored
    # or fetched at runtime via TPM. tmux.conf references its scripts via
    # $NIX_OUT_TMUX/.config/tmux/plugins/resurrect/...
    {
      source = "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect";
      target = ".config/tmux/plugins/resurrect";
    }
  ];
  self = pkgs.symlinkJoin {
    name = "tmux-with-config";
    paths = [
      pkgs.tmux
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "tmux";
      staticEnv = {
        TMUX_SHELL = "${zsh}/bin/zsh";
        NIX_OUT_TMUX = "@OUT@";
        NIX_OUT_TMUX_SESSIONS = "${tmuxSessions}/bin/tmux-sessions";
        # The switcher shells out to tmux; a popup inherits the server's PATH,
        # which is not guaranteed to contain it.
        TMUX_SESSIONS_TMUX = "@OUT@/bin/tmux";
      };
      flags = [
        "-f"
        "$PERMEANCE_ROOT/.config/tmux/tmux.conf"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "tmux";
      description = "Verify tmux config syntax is valid and uses the zsh wrapper";
      script = ''
        # No explicit -f — let the launcher's flags = [ "-f" "$PERMEANCE_ROOT/.config/tmux/tmux.conf" ]
        # provide it, so the smoke exercises the launcher's flag routing.
        if ${self}/bin/tmux start-server \; kill-server 2>/dev/null; then
          ok "config syntax valid (via launcher -f routing)"
        else
          fail "config syntax error"
        fi

        tmux_shell=$(${self}/bin/tmux start-server \; show-option -gv default-shell \; kill-server 2>/dev/null)
        if [ "$tmux_shell" = "${zsh}/bin/zsh" ]; then
          ok "default-shell is zsh wrapper"
        else
          fail "default-shell is '$tmux_shell', expected '${zsh}/bin/zsh'"
        fi

        # The M-Tab popup binding resolves the switcher through this variable,
        # so a broken path here silently turns Alt+Tab into a no-op.
        switcher=$(${self}/bin/tmux start-server \; show-environment -g NIX_OUT_TMUX_SESSIONS \; kill-server 2>/dev/null | cut -d= -f2-)
        if [ -x "$switcher" ]; then
          ok "session switcher exported and executable"
        else
          fail "NIX_OUT_TMUX_SESSIONS is '$switcher', not an executable"
        fi

        if "$switcher" >/dev/null 2>&1; then
          fail "switcher exited 0 with no tmux server running"
        else
          ok "switcher exits non-zero when there are no sessions"
        fi
      '';
    };
  };
in
self
