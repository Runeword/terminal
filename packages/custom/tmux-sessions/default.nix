{ pkgs }:

pkgs.buildGoModule {
  pname = "tmux-sessions";
  version = "0.1.0";
  src = ./.;
  # Stdlib only — raw-mode termios is done via ioctl rather than
  # golang.org/x/term precisely to keep this null.
  vendorHash = null;
}
