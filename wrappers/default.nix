{
  pkgs,
  configPath,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };
  tests = import ../lib/tests.nix { inherit pkgs; };
  git = import ./git.nix { inherit pkgs files tests; };
  claude = import ./claude.nix {
    inherit
      pkgs
      files
      tests
      git
      ;
  };
  zsh = import ./zsh.nix {
    inherit
      pkgs
      files
      tests
      claude
      ;
  };
in
{
  inherit zsh claude git;
  tmux = import ./tmux.nix {
    inherit
      pkgs
      files
      tests
      zsh
      ;
  };
  bat = import ./bat.nix { inherit pkgs files tests; };
  fd = import ./fd.nix { inherit pkgs files tests; };
  ripgrep = import ./ripgrep.nix { inherit pkgs files tests; };
  bash = import ./bash.nix { inherit pkgs files tests; };
  starship = import ./starship.nix { inherit pkgs files tests; };
  delta = import ./delta.nix { inherit pkgs files tests; };
  navi = import ./navi.nix { inherit pkgs files tests; };
  nvim-fzf = import ./nvim-fzf.nix { inherit pkgs files tests; };
}
