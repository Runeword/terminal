{
  pkgs,
  files,
  tests,
  zsh,
}:

let
  self = pkgs.symlinkJoin {
    name = "tmux-with-config";
    paths = [ pkgs.tmux ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      ${files.sync "tmux/tmux.conf" ".config/tmux/tmux.conf"}
      ${files.sync "tmux/scripts/toggle-pane.sh" ".config/tmux/scripts/toggle-pane.sh"}
      ${files.sync "shell/functions/tmux.sh" ".config/shell/functions/tmux.sh"}
      ${files.copy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}

      wrapProgram $out/bin/tmux \
        --set TMUX_SHELL ${zsh}/bin/zsh \
        --set NIX_OUT_TMUX "$out" \
        --add-flags "-f $out/.config/tmux/tmux.conf"
    '';
    passthru.tests.smoke = tests.smoke {
      name = "tmux";
      description = "Verify tmux config syntax is valid and uses the zsh wrapper";
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
      '';
    };
  };
in
self
