{
  pkgs,
  configPath,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };
  zsh = import ./zsh.nix { inherit pkgs files; };
  tmux = import ./tmux.nix { inherit pkgs files zsh; };
  claude = import ./claude { inherit pkgs files; };
in
map (path: import path { inherit pkgs files; }) [
  ./bat.nix
  ./fd.nix
  ./ripgrep.nix
  ./bash.nix
  ./starship.nix
  ./delta.nix
  ./navi.nix
  ./nvim-fzf.nix
]
++ [
  zsh
  tmux
  claude
]
