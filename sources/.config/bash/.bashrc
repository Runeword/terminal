# Config paths below resolve via $PERMEANCE_TREE — permeance's exported
# resolved-root alias: the live tree when a root override is set, else this
# wrapper's own bundled $out. ($NIX_OUT_* stays for store-baked assets.)
[ -f "$PERMEANCE_TREE/.config/shell/xdg.sh" ] && source "$PERMEANCE_TREE/.config/shell/xdg.sh"
[ -f "$PERMEANCE_TREE/.config/shell/variables.sh" ] && source "$PERMEANCE_TREE/.config/shell/variables.sh"

# disable bold in the ls command output
# LS_COLORS=${LS_COLORS//01;/00;}
# export LS_COLORS
# export EDITOR=nvim

export HISTFILE="${XDG_STATE_HOME}"/bash/history
HISTSIZE=100000
HISTFILESIZE=100000

# source "$PERMEANCE_TREE/.config/shell/scripts/ssh-agent.sh"

# # Show completion options on first Tab, cycle through on second Tab
# bind 'set show-all-if-ambiguous on'
# bind 'set menu-complete-display-prefix on'
# bind '"\t": menu-complete'
# bind '"\e[Z": menu-complete-backward' # Shift+Tab for reverse completion

bind -x '"\C-b":"br -c :open_preview"'
bind -x '"\C-n":"__nextd"'
bind -x '"\C-p":"__prevd"'

# unbind alt-number
for i in "-" {0..9}; do bind -r "\e$i"; done

# unbind ctrl-s and ctrl-q (terminal scroll lock)
stty -ixon

[ -f "$PERMEANCE_TREE/.config/shell/aliases.sh" ] && source "$PERMEANCE_TREE/.config/shell/aliases.sh"

if [ -d "$PERMEANCE_TREE/.config/shell/functions" ]; then
  for file in "$PERMEANCE_TREE/.config/shell/functions"/*.{sh,bash}; do
    [ -f "$file" ] && . "$file"
  done
fi

command -v navi >/dev/null 2>&1 && eval "$(navi widget bash)"
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init --no-cmd bash)"
command -v direnv >/dev/null 2>&1 && eval "$(direnv hook bash)"

if [[ :$SHELLOPTS: =~ :(vi|emacs): ]]; then
  . "$(fzf-share)/completion.bash"
  . "$(fzf-share)/key-bindings.bash"
fi
