{ pkgs, mkConfig }:

let
  zsh = import ./zsh.nix { inherit pkgs mkConfig; };
in

pkgs.symlinkJoin {
  name = "tmux-with-config";
  paths = [ pkgs.tmux ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${mkConfig "tmux/tmux.conf" ".config/tmux/tmux.conf"}
    ${mkConfig "shell/functions/tmux.sh" ".config/shell/functions/tmux.sh"}
    ${pkgs.lib.mkCopy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}

    wrapProgram $out/bin/tmux \
    --set TMUX_SHELL ${zsh}/bin/zsh \
    --set TMUX_OUT "$out" \
    --add-flags "-f $out/.config/tmux/tmux.conf"
  '';
}

# ${pkgs.lib.mkCopy ./../../config/tmux/tmux.conf ".config/tmux/tmux.conf"}
# ${pkgs.lib.mkCopy ./../../config/shell/functions/tmux.sh ".config/shell/functions/tmux.sh"}
# ${pkgs.lib.mkCopy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}

# ${pkgs.lib.mkCopy (pkgs.lib.cleanSource ./../../config/tmux/tmux.conf) ".config/tmux/tmux.conf"}
# ${pkgs.lib.mkCopy (pkgs.lib.cleanSource ./../../config/shell/functions/tmux.sh) ".config/shell/functions/tmux.sh"}
# ${pkgs.lib.mkCopy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}
