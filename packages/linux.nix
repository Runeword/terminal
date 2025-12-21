{ pkgs }:

pkgs.lib.optionals (pkgs.stdenv.isLinux) (with pkgs; [
  wl-clipboard # copy/paste
  dragon-drop # drag and drop
  nvme-cli # NVMe storage devices manager
  hwinfo # hardware info
  evtest # input device testing
  libinput # input device handling
  # ventoy-full # USB boot utility
  dmidecode
  cloneit
  xarchiver
  git-graph
  distrobox
  qdirstat # Disk usage viewer
])
