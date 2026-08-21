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
  # Shared-context journal for Claude sessions in the same CLAUDE_CONTEXT_GROUP.
  # The hook half is wired into claude's PATH via wrappers/claude.nix; here so
  # `claude-context log` is runnable from a shell or tmux pane.
  (import ./claude-context { inherit pkgs; })
  # fzf-query compiler shared by fm_rg.sh and fm_preview.sh (interactive file
  # search). Here so it lands in packages.tools and is on the interactive PATH
  # inside the terminal, where fzf's reload/preview commands invoke it.
  (import ./fm-query { inherit pkgs; })
]
