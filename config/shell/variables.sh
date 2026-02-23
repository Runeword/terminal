#!/bin/sh

export EDITOR="nvim"
export VISUAL="nvim"
export MANPAGER="nvim +Man!"
export BROWSER="Firefox"
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
export FZF_DEFAULT_OPTS="
--gutter=' ' \
--color=fg:#d0d0d0,bg:-1,hl:#ffffff \
--color=fg+:#ffffff,fg+:regular,bg+:#142926,hl+:#67c9d6,hl+:regular,query:italic \
--color=info:#d0d0d0,prompt:#ffffff,pointer:#7272ed,border:#2f394a \
--color=marker:#4534bf,spinner:#ffffff,header:#535e73 \
--bind='tab:select+down,btab:deselect+up' \
--bind='up:up,down:down' \
--bind='ctrl-j:down,ctrl-k:up' \
--bind='page-up:half-page-up,page-down:half-page-down' \
--bind='home:first,end:last' \
--bind='shift-up:preview-up,shift-down:preview-down' \
--bind='shift-page-up:preview-up+preview-up+preview-up+preview-up,shift-page-down:preview-down+preview-down+preview-down+preview-down' \
--bind='shift-home:preview-top,shift-end:preview-bottom' \
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

# --color=fg+:#ffffff,fg+:regular,bg+:-1,hl+:#6bdbd8,hl+:regular,query:regular \
# --color=fg+:#ffffff,fg+:regular,bg+:#262626,hl+:#6bdbd8,hl+:regular,query:regular \
