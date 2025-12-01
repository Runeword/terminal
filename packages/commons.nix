# List of extra packages to include
{ pkgs }:

with pkgs; [
  cowsay
  yazi # file manager
  navi # cheat sheet
  ueberzugpp # images support for terminal
  gmailctl
  sqlite
  progress
  # qmk # Temporarily disabled due to wb32-dfu-updater CMake version compatibility issue
  httrack
  chezmoi
  gh
  xdg-ninja
  direnv
  pass
  gemini-cli-bin
  cursor-cli
  claude-code
  bitwarden-cli

  # Coreutils
  coreutils-full
  util-linux # provides the linux version of the column command
  zoxide
  gomi
  fzf
  tree
  wget
  jq
  sshs

  # Monitoring
  htop
  btop
  procs
  gping
  hyperfine # benchmarking
  lsof

  # Development
  atac
  ngrok
  awscli2
  lefthook

  # Archivers
  ouch
  unzip

  # Versioning
  lazygit
  gitleaks
  git # versioning
  git-absorb # auto git commit --fixup
  zsh-forgit # fuzzy git

  # Containers
  lazydocker
  docker-compose
  #terraform

  # Files
  miller # cvs toolbox
  glow # markdown

  # Info
  onefetch # Git info
  neofetch # System info

  # Nix
  nix-prefetch-docker
  nix-init
  cachix
  devenv

  # Multimedia
  asciinema # Terminal recorder
  lux # Video downloader
  qrcp # mobile QR files transfer

  # Disk
  ncdu
  erdtree # Disk usage
] 
