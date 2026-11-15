# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# The bundled .zshrc: its keys (Shift+Space, Home/End, Shift+Tab, Tab,
# Alt+H), the empty-prompt shortcuts, fpath, and a start with a cache home
# inherited from elsewhere.

# Shift+Space types a space, as Space does (zsh -i also prints .zshrc's
# timing line, hence the case).
case "$(@zsh@/bin/zsh -i -c 'bindkey "^[[32;2u"' 2>/dev/null)" in
  *'"^[[32;2u" " "'*) ok "the bundled .zshrc has Shift+Space type a space" ;;
  *) fail "the bundled .zshrc does not have Shift+Space type a space" ;;
esac

# Home/End work in Alacritty and in tmux, which send them differently.
case "$(@zsh@/bin/zsh -i -c 'for k in "^[[H" "^[[1~" "^[[F" "^[[4~"; do bindkey "$k"; done' 2>/dev/null)" in
  *'"^[[H" beginning-of-line'*'"^[[1~" beginning-of-line'*'"^[[F" end-of-line'*'"^[[4~" end-of-line'*) ok "Home/End are bound as Alacritty and tmux send them" ;;
  *) fail "Home/End are unbound as Alacritty or tmux sends them" ;;
esac

# The bundled .zshrc loads and binds Shift+Tab to that search (zsh -i
# also prints .zshrc's timing line, hence the case).
case "$(@zsh@/bin/zsh -i -c 'bindkey "^[[Z"' 2>/dev/null)" in
  *'"^[[Z" __ripgrep_or_menu_'*) ok "the bundled .zshrc binds Shift+Tab to the search" ;;
  *) fail "the bundled .zshrc does not bind Shift+Tab to the search" ;;
esac

# On a typed line, Tab fills in a suggestion showing at the end of the
# line, with no space after it, where Esc adds one; with the cursor
# inside the line, or no suggestion yet, it opens the completion menu,
# and it never runs the line. Outside zle the test sets the line
# itself, and a stand-in zle records the widgets called and fills the
# suggestion in as autosuggest-accept does.
tabs='zle() { print -r -- "zle $*"; [[ $1 != autosuggest-accept ]] || BUFFER+=$POSTDISPLAY POSTDISPLAY=; }
  BUFFER="git sta" POSTDISPLAY=tus CURSOR=7; __tab_handler; print -r -- "[$BUFFER]"
  BUFFER="git sta" POSTDISPLAY=tus CURSOR=3; __tab_handler
  BUFFER="git sta" POSTDISPLAY= CURSOR=7; __tab_handler
  BUFFER="git sta" POSTDISPLAY=tus CURSOR=7; __ls_or_escape; print -r -- "[$BUFFER]"'
tabbed=$(@zsh@/bin/zsh -i -c "$tabs" 2>/dev/null)
case "$tabbed" in
  *"$(printf 'zle autosuggest-accept\nzle redisplay\n[git status]\nzle menu-select\nzle menu-select\nzle autosuggest-accept\nzle redisplay\nzle reset-prompt\n[git status ]')") ok "Tab fills in a suggestion showing at the end of the line with no space after it, where Esc adds one, and otherwise opens the completion menu" ;;
  *) fail "Tab does not fill in a suggestion showing at the end of the line without a space after it (or Esc with one), or does not open the completion menu otherwise: $tabbed" ;;
esac

# Alt+H asks Claude Haiku to explain the typed line: the line reaches
# claude on stdin as text, never run, with what the shell says its
# words are (a function's code too), and claude runs with no tools,
# nothing saved, only the user's settings and no CLAUDE_CONFIG_DIR, so
# with the host's own profile, signed in with pass's claude/oauth-token
# in its environment, read with bracketed paste off so that a pasted
# passphrase reaches gpg as is; its answer shows under the line. A
# line that looks like it holds a secret is not sent, and Alt+Shift+H
# is still zsh's run-help, which hands the command to man. Stand-ins:
# a claude that records what it got, pass, a zle that prints -M
# messages, man.
mkdir -p "$HOME/explain/bin"
printf '#!/bin/sh\necho "config=$CLAUDE_CONFIG_DIR token=$CLAUDE_CODE_OAUTH_TOKEN $*" > "$HOME/explain/args"\ncat > "$HOME/explain/stdin"\necho It lists commits.\n' >"$HOME/explain/bin/claude"
printf '#!/bin/sh\n[ "$*" = "show claude/oauth-token" ] && echo sk-ant-oat01-fake\n' >"$HOME/explain/bin/pass"
chmod +x "$HOME/explain/bin/claude" "$HOME/explain/bin/pass"
explain='path=($HOME/explain/bin $path); export CLAUDE_CONFIG_DIR=$HOME/.claude-1
  zle() { [[ $1 != -M ]] || print -r -- "M: $argv[-1]"; }
  man() { print -r -- "man $*"; }
  bindkey "^[h"; bindkey "^[H"
  BUFFER="echo \$(touch $HOME/ran) | __copy"; __explain_line
  BUFFER="export GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxx"; __explain_line
  run-help rsync'
explained=$(
  @zsh@/bin/zsh -i -c "$explain" 2>/dev/null || :
  cat "$HOME/explain/args" "$HOME/explain/stdin" 2>/dev/null || :
)
case "$explained" in
  *'"^[h" __explain_line'*'"^[H" run-help'*'[?2004l'*'[?2004h'*'M: It lists commits.'*'M: Not sent: the line looks like it holds a secret.'*'man rsync'*'config= token=sk-ant-oat01-fake -p '*'--tools  --strict-mcp-config --no-session-persistence --setting-sources user '*'Command line: echo $(touch '*'/ran) | __copy'*'__copy () {'*)
    if [ -e "$HOME/ran" ]; then
      fail "Alt+H ran the typed line it was to explain"
    else
      ok "Alt+H has Claude Haiku explain the typed line, sent as text with what its words are to a claude with no tools, nothing saved, the host's profile and the token in pass, shows the answer under the line and holds back a line that looks like a secret, and Alt+Shift+H is still run-help"
    fi
    ;;
  *) fail "Alt+H does not send the typed line as text with what its words are to a tool-less claude, does not show the answer under the line or sends a secret, or Alt+Shift+H is no longer run-help: $explained" ;;
esac

# The empty-prompt shortcuts (Shift+Delete, Esc, Shift+Esc) fire only at
# the prompt itself, where zle sets CONTEXT to start. The line is empty
# on a continuation line (cont), in a select menu (select) and in vared
# (vared) too, and there they must leave it alone. Outside zle the test
# sets CONTEXT itself; the shortcut fails on purpose, since a success
# would run the prompt's precmd hooks.
contexts='BUFFER=
  for CONTEXT in cont select vared start; do
    __on_empty_buffer "print EMPTY; false" "print LINE"
  done'
case "$(@zsh@/bin/zsh -i -c "$contexts" 2>/dev/null | tr '\n' ' ')" in
  *"LINE LINE LINE EMPTY ") ok "the empty-prompt shortcuts fire only at the prompt, not on a continuation line, in a select menu or in vared" ;;
  *) fail "an empty-prompt shortcut fires on a continuation line, in a select menu or in vared, or not at the prompt" ;;
esac

# The tools' completions, which the alacritty launcher exports as one
# directory, go on fpath.
case "$(TERMINAL_ZSH_COMPLETIONS=/tools-completions @zsh@/bin/zsh -i -c 'print -l -- $fpath' 2>/dev/null)" in
  *"/tools-completions"*) ok "the tools' completions directory is on fpath" ;;
  *) fail "the tools' completions directory is not on fpath" ;;
esac

# zsh's caches live under the cache home xdg.sh sets, in a directory
# made after it: started with a cache home inherited from elsewhere,
# the start still loads the tools' hooks (direnv's here) and dircolors'
# colours, and says nothing of a cache it could not write.
mkdir -p "$HOME/xdgc/home" "$HOME/xdgc/cache"
# shellcheck disable=SC2097,SC2098 # zsh gets its own HOME; its errors go under this one
xdgc=$(HOME=$HOME/xdgc/home XDG_CACHE_HOME=$HOME/xdgc/cache PATH=@direnv@/bin:$PATH @zsh@/bin/zsh -i -c 'print -r -- "${+functions[_direnv_hook]} ${#LS_COLORS}"' 2>"$HOME/xdgc/err" | tail -n 1)
if [ "${xdgc%% *}" = 1 ] && [ "${xdgc#* }" -gt 0 ] && ! grep -q "no such file" "$HOME/xdgc/err"; then
  ok "with a cache home inherited from elsewhere, the start still loads the tools' hooks and dircolors' colours"
else
  fail "with a cache home inherited from elsewhere, the start loses the tools' hooks or dircolors' colours: $xdgc $(cat "$HOME/xdgc/err")"
fi
