{ pkgs, configPath }:
let
  files = import ../lib/files.nix { inherit pkgs; rootPath = configPath; };
in
map (path: import path { inherit pkgs files; }) [
  ./zsh.nix
  ./tmux.nix
  ./bat.nix
  ./fd.nix
  ./ripgrep.nix
  ./bash.nix
  ./starship.nix
  ./delta.nix
]
