{
  pkgs,
  configPath,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };
in
rec {
  zsh = import ./zsh.nix { inherit pkgs files; };
  tmux = import ./tmux.nix { inherit pkgs files zsh; };
  claude = import ./claude { inherit pkgs files; };
  bat = import ./bat.nix { inherit pkgs files; };
  fd = import ./fd.nix { inherit pkgs files; };
  ripgrep = import ./ripgrep.nix { inherit pkgs files; };
  bash = import ./bash.nix { inherit pkgs files; };
  starship = import ./starship.nix { inherit pkgs files; };
  delta = import ./delta.nix { inherit pkgs files; };
  navi = import ./navi.nix { inherit pkgs files; };
  nvim-fzf = import ./nvim-fzf.nix { inherit pkgs files; };
}
