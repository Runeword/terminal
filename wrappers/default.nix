{
  pkgs,
  configPath,
  permeance,
}:
let
  files = import ../lib/files.nix {
    inherit pkgs;
    rootPath = configPath;
  };
  tests = import ../lib/tests.nix { inherit pkgs; };
  git = import ./git.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  claude = import ./claude.nix {
    inherit
      pkgs
      files
      permeance
      tests
      git
      ;
  };
  zsh = import ./zsh.nix {
    inherit
      pkgs
      files
      permeance
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
      permeance
      tests
      zsh
      ;
  };
  bat = import ./bat.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  fd = import ./fd.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  ripgrep = import ./ripgrep.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  bash = import ./bash.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  starship = import ./starship.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  delta = import ./delta.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  navi = import ./navi.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
  nvim-fzf = import ./nvim-fzf.nix {
    inherit
      pkgs
      files
      permeance
      tests
      ;
  };
}
