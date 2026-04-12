{
  pkgs,
  configPath,
  lefthook,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };
  claudePlugins = import ./claude-plugins.nix { inherit pkgs; };
  zsh = import ./zsh.nix { inherit pkgs files claudePlugins; };
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
  (import ./tmux.nix { inherit pkgs files zsh; })
  (import ./claude.nix {
    inherit pkgs files lefthook;
  })
]
