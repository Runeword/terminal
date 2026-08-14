{
  pkgs,
  files,
  permeance,
  zsh,
}:

let
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
      };
      flags = [
        "-f"
        "$PERMEANCE_ROOT/.config/tmux/tmux.conf"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "tmux";
      description = "Verify tmux config syntax is valid, uses the zsh wrapper, enables resurrect pane-content capture, limits passthrough to visible panes, and yanks via copy-selection";
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

        cap=$(${self}/bin/tmux start-server \; show-option -gqv @resurrect-capture-pane-contents \; kill-server 2>/dev/null)
        if [ "$cap" = "on" ]; then
          ok "resurrect pane-content capture enabled"
        else
          fail "@resurrect-capture-pane-contents is '$cap', expected 'on'"
        fi

        # allow-passthrough is a pane option; its global default lives in the
        # window/pane table, so -gw (a plain -g comes back empty).
        passthrough=$(${self}/bin/tmux start-server \; show-options -gwv allow-passthrough \; kill-server 2>/dev/null)
        if [ "$passthrough" = "on" ]; then
          ok "allow-passthrough limited to visible panes"
        else
          fail "allow-passthrough is '$passthrough', expected 'on'"
        fi

        yank=$(${self}/bin/tmux start-server \; list-keys -T copy-mode-vi y \; kill-server 2>/dev/null)
        case "$yank" in
          *copy-selection*) ok "copy-mode-vi y yanks via copy-selection" ;;
          *) fail "copy-mode-vi y is '$yank', expected copy-selection" ;;
        esac
      '';
    };
  };
in
self
