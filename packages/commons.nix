# List of extra packages to include
{ pkgs }:

with pkgs;
[
  yazi # file manager
  ueberzugpp # images support for terminal
  gmailctl
  progress
  # qmk
  chezmoi
  xdg-ninja
  pass
  httrack

  # _______________________________ CLI
  bitwarden-cli
  gh
  google-cloud-sdk
  firebase-tools

  # _______________________________ AI
  gemini-cli-bin
  cursor-cli
  claude-code

  # _______________________________ Coreutils
  coreutils-full
  util-linux # provides the linux version of the column command
  zoxide
  gomi
  fzf
  tree
  wget
  jq
  sshs

  # _______________________________ Monitoring
  htop
  btop
  procs
  gping
  hyperfine
  lsof

  # _______________________________ Development
  cowsay
  atac
  ngrok
  awscli2
  sqlite

  # _______________________________ Archivers
  ouch
  unzip

  # _______________________________ Git
  git
  gitleaks # security scan
  lazygit # tui
  onefetch # info
  lefthook # hooks
  git-absorb # auto git commit --fixup
  zsh-forgit # fuzzy git

  # _______________________________ Infra
  lazydocker
  docker-compose
  # terraform

  # _______________________________ Files
  miller # cvs toolbox
  glow # markdown

  # Info
  neofetch # System info

  # _______________________________ Nix
  nix-prefetch-docker
  nix-init
  cachix
  devenv
  direnv

  # _______________________________ Multimedia
  asciinema # Terminal recorder
  lux # Video downloader
  qrcp # mobile QR files transfer

  # _______________________________ Disk
  ncdu # Disk usage tui
  erdtree # Disk usage cli
]
