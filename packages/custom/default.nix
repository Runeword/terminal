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
  # Emits the TIOCSTI/TIOCLINUX seccomp filter (seccomp_export_bpf format) that
  # claude-sandbox.bash feeds to bwrap's --seccomp. Here so it lands in
  # packages.tools and is on the interactive/host PATH, where the launcher runs
  # it before exec'ing into the namespace.
  (import ./claude-seccomp-bpf { inherit pkgs; })
  # Builds the sanitized ~/.ssh copy (config + in-tree Includes + known_hosts +
  # one .pub per IdentityFile, never a private key) that claude-sandbox.bash
  # binds into the namespace. Same reason it is here: the launcher invokes it on
  # the interactive/host PATH before exec'ing into bwrap.
  (import ./claude-ssh-sanitize { inherit pkgs; })
  # Decides whether claude-sandbox.bash may bind the cwd read-write (refuses
  # $HOME/XDG-root/login-exec-tree cwds). The launcher passes the physical cwd
  # and calls it before building the namespace; here for the same host-PATH reason.
  (import ./claude-cwd-gate { inherit pkgs; })
]
