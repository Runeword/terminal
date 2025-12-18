{ pkgs }:

let
  zsh = import ./zsh.nix { inherit pkgs; };
in

pkgs.symlinkJoin {
  name = "tmux-with-config";
  paths = [ pkgs.tmux ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${pkgs.lib.mkConfig "tmux/tmux.conf" ".config/tmux/tmux.conf"}
    ${pkgs.lib.mkConfig "shell/functions/tmux.sh" ".config/shell/functions/tmux.sh"}
    ${pkgs.lib.mkCopy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}

    wrapProgram $out/bin/tmux \
    --set TMUX_SHELL ${zsh}/bin/zsh \
    --set NIX_OUT_TMUX "$out" \
    --add-flags "-f $out/.config/tmux/tmux.conf"
  '';
}
