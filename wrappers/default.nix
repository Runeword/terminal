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
  git = import ./git.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  claude = import ./claude.nix {
    inherit
      pkgs
      files
      permeance
      git
      ;
  };
  zsh = import ./zsh.nix {
    inherit
      pkgs
      files
      permeance
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
      zsh
      ;
  };
  bat = import ./bat.nix {
    inherit
      pkgs
      files
      permeance
      configPath
      ;
  };
  fd = import ./fd.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  ripgrep = import ./ripgrep.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  bash = import ./bash.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  starship = import ./starship.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  delta = import ./delta.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  navi = import ./navi.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
  nvim-fzf = import ./nvim-fzf.nix {
    inherit
      pkgs
      files
      permeance
      ;
  };
}
