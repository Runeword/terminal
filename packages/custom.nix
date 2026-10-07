{ pkgs }:

[
  (pkgs.buildGoModule {
    pname = "git-branches";
    version = "0.1.0";
    src = ./git/branches;
    vendorHash = "sha256-uqVw/+79vkCQCF4QdP5LIo8CWdUoXRDaWFhYwr5QbT4=";
    # TestStashApplyCmd runs the printed command in a real repo.
    nativeCheckInputs = [ pkgs.git ];
  })
  # Shared-context journal for Claude sessions in the same CLAUDE_CONTEXT_GROUP.
  # The hook half is wired into claude's PATH via wrappers/claude.nix; here so
  # `claude-context log` is runnable from a shell or tmux pane.
  (import ./claude/context { inherit pkgs; })
  # Lists, previews and erases Claude Code sessions (Claude Code can't delete
  # one). Backs the session picker behind the cs leader alias
  # (sources/.config/shell/functions/claude.bash). Here so it lands in
  # packages.tools and is on the interactive PATH inside the terminal, where
  # that picker and its fzf preview invoke it by bare name.
  (import ./claude/sessions { inherit pkgs; })
  # fzf-query compiler shared by fm_rg.sh and fm_preview.sh (interactive file
  # search). Here so it lands in packages.tools and is on the interactive PATH
  # inside the terminal, where fzf's reload/preview commands invoke it.
  (import ./fm-query { inherit pkgs; })
  # Splits a git diff into selectable hunks and reassembles a chosen subset into
  # a valid patch. Backs the interactive hunk pickers behind the grd/gru leader
  # aliases (sources/.config/shell/functions/git.bash). Here so it lands in
  # packages.tools and is on the interactive PATH inside the terminal, where
  # those functions and their fzf preview invoke it by bare name.
  (import ./git/hunk-pick { inherit pkgs; })
  # Turns a picked subset of working-tree changes (a patch on stdin + untracked
  # files) into one real stash via temp-index plumbing, without touching the
  # index. Backs the hunk path of the gsp leader alias's two-level picker
  # (sources/.config/shell/functions/git.bash); on packages.tools PATH so
  # __git_pick_files invokes it by bare name.
  (import ./git/stash-hunks { inherit pkgs; })
  # Renders sources/.config/shell/leader.toml into the fzf rows behind the
  # leader-key picker (sources/.config/shell/functions/aliases.sh). Here so it
  # lands in packages.tools and is on the interactive PATH inside the terminal,
  # where the zle widget invokes it by bare name.
  (import ./leader-aliases { inherit pkgs; })
]
