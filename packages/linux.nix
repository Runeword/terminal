{ pkgs }:

pkgs.lib.optionals pkgs.stdenv.isLinux (
  with pkgs;
  [
    xdg-utils
    wl-clipboard # copy/paste
    dragon-drop # drag and drop
    nvme-cli # NVMe storage devices manager
    hwinfo # hardware info
    evtest # input device testing
    libinput # input device handling
    # ventoy-full # USB boot utility
    dmidecode
    # claude-sandbox.bash launcher (.config/shell/functions/claude.bash gates on
    # `command -v bwrap` in the interactive shell, not on claude's inner PATH)
    bubblewrap
    cloneit
    xarchiver
    git-graph
    distrobox
    qdirstat # Disk usage viewer
  ]
)
