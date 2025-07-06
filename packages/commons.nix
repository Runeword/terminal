# List of extra packages to include
{ pkgs }:

with pkgs; [
  cowsay
  yazi # file manager
  navi # cheat sheet
  starship # prompt
  ueberzugpp # images support for terminal
  nix-prefetch-docker
  gmailctl
  sqlite
  progress
  qmk
  httrack
  chezmoi
  gh
  xdg-ninja
  direnv
  pass
  gemini-cli

  # Coreutils
  coreutils-full
  util-linux # provides the linux version of the column command
  bat
  zoxide
  gomi
  ripgrep
  fd
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
  git-absorb
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
  nix-init
  cachix

  # Multimedia
  asciinema # Terminal recorder
  lux # Video downloader
  qrcp # mobile QR files transfer

  # Disk
  ncdu
  erdtree # Disk usage
] 
