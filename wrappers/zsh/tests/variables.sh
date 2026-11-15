# shellcheck shell=bash
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
#
# variables.sh: the options every fzf picker, and forgit's, start with.

# In every fzf picker (FZF_DEFAULT_OPTS), nothing is bound to f or y,
# so that they type into the query with the search on or off, and no
# key labels the rows to jump to one.
fzf_opts=$(@zsh@/bin/zsh -i -c 'print -r -- "$FZF_DEFAULT_OPTS"' 2>/dev/null)
case "$fzf_opts" in
  *jump* | *"'f:"* | *",f:"* | *"'y:"* | *",y:"*) fail "f or y does not type into every fzf picker's query, or a key labels the rows to jump to one" ;;
  *"start:unbind("*) ok "f and y type into every fzf picker's query with the search on or off, and no key labels the rows to jump to one" ;;
  *) fail "the fzf pickers' options are not set" ;;
esac

# With the search off, j/k move 1 row or 5: ctrl-j/k switch f12/f11,
# which add the 4 more rows, and press j/k; from the search they turn
# it off and unbind f12/f11, and so does every switch of the search.
case "$fzf_opts" in
  *'+unbind(f12,f11)+trigger(j)" || echo "toggle-bind(f12,f11)+trigger(j)"'*"j:trigger(f12)+down,k:trigger(f11)+up"*"f12:down+down+down+down,f11:up+up+up+up"*"i:toggle-search+toggle-bind(j,k,g,G,i,q,J,K)+unbind(f12,f11)"*"start:unbind(j,k,g,G,i,q,J,K,f12,f11)"*) ok "with the search off, each ctrl-j/k switches j/k between 1 and 5 rows and moves one step, and the search's switches reset them to 1" ;;
  *) fail "ctrl-j/k do not switch j/k between 1 and 5 rows with the search off, or a switch of the search keeps the 5-row step" ;;
esac

# Every switch of the search switches J/K with j/k, though nothing
# here binds them: a picker that does (gl, to scroll its preview) has
# them with the search off only, and one that doesn't types them into
# its query.
case "$fzf_opts" in
  *"toggle-bind(j,k,g,G,i,q)"* | *"'J:"* | *",J:"* | *"'K:"* | *",K:"*) fail "a switch of the search leaves J/K as they are, or every fzf picker binds them" ;;
  *'ctrl-j:transform{'*'toggle-bind(j,k,g,G,i,q,J,K)'*'ctrl-k:transform{'*'toggle-bind(j,k,g,G,i,q,J,K)'*"i:toggle-search+toggle-bind(j,k,g,G,i,q,J,K)+"*"start:unbind(j,k,g,G,i,q,J,K,f12,f11)"*"alt-i:toggle-search+toggle-bind(j,k,g,G,i,q,J,K)+"*'esc:transform{'*'toggle-bind(j,k,g,G,i,q,J,K)'*) ok "every switch of the search switches J/K with j/k, which only the pickers that bind them have" ;;
  *) fail "a switch of the search leaves J/K as they are, or every fzf picker binds them" ;;
esac

# forgit's pickers (gkf, gbm, …) open as the git pickers do: the
# search off, the cursor stopping at either end of the list, and the
# preview below it.
case "$(@zsh@/bin/zsh -i -c 'print -r -- "$FORGIT_FZF_DEFAULT_OPTS"' 2>/dev/null)" in
  *" --cycle"*) fail "forgit's pickers wrap around at the ends of their list" ;;
  *"--no-cycle "*"--preview-window down,75%,border-top,"*"start:+trigger(alt-i)"*) ok "forgit's pickers start with the search off, stop at either end of their list and preview below it, as the git pickers do" ;;
  *) fail "forgit's pickers start with the search on or preview beside their list" ;;
esac
