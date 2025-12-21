{ pkgs, files }:

let
  zsh = import ./zsh.nix { inherit pkgs files; };
in

pkgs.symlinkJoin {
  name = "tmux-with-config";
  paths = [ pkgs.tmux ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "tmux/tmux.conf" ".config/tmux/tmux.conf"}
    ${files.sync "shell/functions/tmux.sh" ".config/shell/functions/tmux.sh"}
    ${files.copy "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect" ".config/tmux/plugins/resurrect"}

    wrapProgram $out/bin/tmux \
    --set TMUX_SHELL ${zsh}/bin/zsh \
    --set NIX_OUT_TMUX "$out" \
    --add-flags "-f $out/.config/tmux/tmux.conf"
  '';
}
