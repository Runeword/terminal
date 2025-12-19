{ pkgs }:
map (path: import path { inherit pkgs; }) [
  ./zsh.nix
  ./tmux.nix
  ./bat.nix
  ./fd.nix
  ./ripgrep.nix
  ./bash.nix
  ./starship.nix
  ./delta.nix
]
