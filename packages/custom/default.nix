{ pkgs }:

[
  (pkgs.buildGoModule {
    pname = "git-branches";
    version = "0.1.0";
    src = ./git-branches;
    vendorHash = "sha256-uqVw/+79vkCQCF4QdP5LIo8CWdUoXRDaWFhYwr5QbT4=";
  })
  # Renderer for the tmux Claude-sessions dashboard; also the hook writer (wired
  # into claude's PATH via wrappers/claude.nix). Here so it lands in
  # packages.tools and is on the interactive/tmux PATH inside the terminal.
  (import ./claude-session-status { inherit pkgs; })
]
