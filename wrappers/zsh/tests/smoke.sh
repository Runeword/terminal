# shellcheck shell=bash
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
#
# The wrapper itself: it execs the real zsh, and a login shell started
# through it is one.

if @zsh@/bin/zsh --version >/dev/null 2>&1; then
  ok "wrapper execs real zsh"
else
  fail "wrapper does not exec real zsh"
fi

# A login shell started through the wrapper is one: the compiled
# launcher hands zsh the "-zsh" argv[0] its caller gave it, as tmux
# gives every pane's shell (a bash launcher never sees it).
if [ "$(exec -a -zsh @zsh@/bin/zsh -c '[[ -o login ]] && print login')" = login ]; then
  ok "a login shell started through the wrapper is a login shell"
else
  fail "the wrapper loses a login shell's -zsh"
fi
