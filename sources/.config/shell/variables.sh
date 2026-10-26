#!/bin/sh

export EDITOR="nvim"
export VISUAL="nvim"
export MANPAGER="nvim +Man!"
export BROWSER="firefox-devedition"
export HOME_MANAGER_PATH="$HOME/.config/home-manager"
export NIXOS_PATH="$HOME/nixos"
# export BROWSER="google-chrome-stable"

# DIRENV_LOG_FORMAT = "$(tput setaf 0)direnv: %s$(tput sgr0)";
# DIRENV_LOG_FORMAT = ''echo -e "\e[90mdirenv: %s\e[0m"'';

# _____________________________________________ FZF

export FZF_DEFAULT_OPTS_FILE=""
export FORGIT_FZF_DEFAULT_OPTS="
--exact \
--cycle \
--reverse \
--prompt='  ' \
--no-separator \
--info=inline:'' \
--preview-window right,75%,border-none \
--bind='ctrl-a:select-all' \
"
# export FZF_DEFAULT_COMMAND="
# fd \
# --reverse \
# --prompt='  ' \
# --no-separator \
# --info=inline:'' \
# --hidden \
# --follow \
# --no-ignore \
# --exclude .git \
# --exclude node_modules \
# ";

export FZF_COMPLETION_OPTS="
--multi \
--reverse \
--prompt='  ' \
--no-separator \
--info=inline:'' \
"

# --color=marker:#57b58f,spinner:#ffffff,header:#535e73 \
# With the search off, j/k move 1 row or 5: each ctrl-j/k switches between
# the two and moves one step (from the search, it turns the search off and
# moves 1 row). ctrl-j/k press j/k, which add the 4 more rows of f12/f11
# while those are bound (toggle-bind), so j/k start no process. Every switch
# of the search unbinds f12/f11: back to 1 row.
export FZF_DEFAULT_OPTS="
--gutter=' ' \
--color=fg:#d0d0d0,bg:-1,hl:#ffffff \
--color=fg+:#ffffff,fg+:regular,bg+:#142926,hl+:#67c9d6,hl+:regular,query:italic \
--color=info:#d0d0d0,prompt:#ffffff,pointer:#7272ed,border:#2f394a \
--color=marker:#4534bf,spinner:#ffffff,header:#535e73 \
--with-shell='sh -c' \
--bind='tab:select+down,btab:deselect+up' \
--bind='up:up,down:down' \
--bind='ctrl-j:transform{[ \"\$FZF_INPUT_STATE\" = enabled ] && echo \"toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)+trigger(j)\" || echo \"toggle-bind(f12,f11)+trigger(j)\"}' \
--bind='ctrl-k:transform{[ \"\$FZF_INPUT_STATE\" = enabled ] && echo \"toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)+trigger(k)\" || echo \"toggle-bind(f12,f11)+trigger(k)\"}' \
--bind='page-up:half-page-up,page-down:half-page-down' \
--bind='home:first,end:last' \
--bind='shift-up:preview-up,shift-down:preview-down' \
--bind='shift-page-up:preview-up+preview-up+preview-up+preview-up,shift-page-down:preview-down+preview-down+preview-down+preview-down' \
--bind='shift-home:preview-top,shift-end:preview-bottom' \
--bind='j:trigger(f12)+down,k:trigger(f11)+up' \
--bind='f12:down+down+down+down,f11:up+up+up+up' \
--bind='g:first,G:last' \
--bind='q:abort' \
--bind='i:toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)' \
--bind='start:unbind(j,k,g,G,i,q,f12,f11)' \
--bind='alt-i:toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)' \
--bind='esc:transform{[ \"\$FZF_INPUT_STATE\" = enabled ] && echo \"abort\" || echo \"toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)\"}' \
"
# --color=fg+:#ffffff,fg+:regular,bg+:#142920,hl+:#67c9d6,hl+:regular,query:italic \
# --color=marker:#458f71,spinner:#ffffff,header:#535e73 \
# --color=info:#d0d0d0,prompt:#ffffff,pointer:#7272ed,border:#2f394a \
# --color=info:#d0d0d0,prompt:#ffffff,pointer:#67d6bc,border:#2f394a \
# --color=info:#d0d0d0,prompt:#ffffff,pointer:#67d6a9,border:#2f394a \
# --color=fg+:#ffffff,fg+:regular,bg+:#142920,hl+:#67c9d6,hl+:regular,query:italic \
# --color=fg+:#ffffff,fg+:regular,bg+:#142920,hl+:#67d6a9,hl+:regular,query:italic \

export FZF_CTRL_R_OPTS="
--reverse \
--prompt='  ' \
--no-separator \
--info=inline:'' \
"
export FZF_CTRL_T_OPTS="
--reverse \
--prompt='  ' \
--no-separator \
--info=inline:'' \
"

# _____________________________________________ ZOXIDE

export _ZO_FZF_OPTS="$FZF_DEFAULT_OPTS
--bind='ctrl-z:ignore,btab:up,tab:down' \
--no-sort \
--tiebreak=index \
--cycle \
--keep-right \
--border=sharp \
--height=45% \
--info=inline:'' \
--no-separator \
--layout=reverse \
--tabstop=1 \
--exit-0 \
--select-1 \
--preview='\$PERMEANCE_TREE/.config/shell/scripts/zoxide_preview.sh {2..}' \
--preview-window=down,40%,border-top \
"

# --color=fg+:#ffffff,fg+:regular,bg+:-1,hl+:#6bdbd8,hl+:regular,query:regular \
# --color=fg+:#ffffff,fg+:regular,bg+:#262626,hl+:#6bdbd8,hl+:regular,query:regular \
