{
  pkgs,
  files,
  permeance,
  tests,
  zsh,
}:

let
  config = files.mkConfig "tmux-config" [
    ".config/tmux/tmux.conf"
    ".config/tmux/scripts/toggle-pane.sh"
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
    passthru.tests.smoke = tests.smoke {
      name = "tmux";
      description = "Verify tmux config syntax is valid, uses the zsh wrapper, and the launcher resolves PERMEANCE_ROOT";
      script = ''
        if ${self}/bin/tmux -f ${self}/.config/tmux/tmux.conf start-server \; kill-server 2>/dev/null; then
          ok "config syntax valid"
        else
          fail "config syntax error"
        fi

        tmux_shell=$(${self}/bin/tmux -f ${self}/.config/tmux/tmux.conf start-server \; show-option -gv default-shell \; kill-server 2>/dev/null)
        if [ "$tmux_shell" = "${zsh}/bin/zsh" ]; then
          ok "default-shell is zsh wrapper"
        else
          fail "default-shell is '$tmux_shell', expected '${zsh}/bin/zsh'"
        fi

        if grep -q PERMEANCE_ROOT ${self}/bin/tmux \
           && grep -qF '/.config/tmux/tmux.conf' ${self}/bin/tmux; then
          ok "launcher passes -f from PERMEANCE_ROOT"
        else
          fail "launcher missing PERMEANCE_ROOT resolution for -f"
        fi
      '';
    };
  };
in
self
