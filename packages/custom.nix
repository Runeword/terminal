{ pkgs }:

[
  (pkgs.buildGoModule {
    pname = "git-branches";
    version = "0.1.0";
    src = ./git/branches;
    vendorHash = "sha256-zaOS1yyiwq0Jir+A7/UTDVP0ObX1SttUj+Ut93Hfun4=";
    # TestStashApplyCmd runs the printed command in a real repo.
    nativeCheckInputs = [ pkgs.git ];
  })
  # Lists, previews and erases Claude Code sessions (Claude Code can't delete
  # one), and backs up the open ones. Backs the session pickers behind the cs
  # and cx leader aliases, and the backup and its restore behind cb and cbr
  # (sources/.config/shell/functions/claude.bash). Here so it lands in
  # packages.tools and is on the interactive PATH inside the terminal, where
  # those functions and their fzf previews invoke it by bare name.
  (import ./claude/sessions { inherit pkgs; })
  # fzf-query matcher shared by fm_rg.sh and fm_preview.sh (interactive file
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
  # Renders sources/.config/shell/leader.conf into the fzf rows behind the
  # leader-key picker (sources/.config/shell/functions/aliases.sh), and lines
  # up its columns for __leader_edit (-fmt). Here so it lands in
  # packages.tools and is on the interactive PATH inside the terminal, where
  # the zle widget and __leader_edit invoke it by bare name.
  (import ./leader-aliases { inherit pkgs; })
  # Labels a tmux session with what its windows are doing, asking a local
  # model (Qwen3.5 2B through llama.cpp, both pinned in its default.nix) from
  # each pane's program, folder, git branch and title; status-right shows the
  # current session's label (sources/.config/tmux/tmux.conf, whose hooks and
  # M-N run it). Here so it lands in packages.tools: the tmux server gets that
  # PATH from alacritty, and run-shell invokes it by bare name. Its model makes
  # the tools closure 1.3 GB larger.
  (import ./tmux-session-name { inherit pkgs; })
]
