# shellcheck disable=SC2148
# Exit if not interactive shell
[[ -o interactive ]] || { echo "Not an interactive shell"; return; }

typeset -g PROFILE_ZSH=${PROFILE_ZSH:-0}
# typeset -g PROFILE_ZSH=1

# Helper function for conditional profiling output
_profile() { (( PROFILE_ZSH )) && printf "$@" || true; }

# Start timer for zsh load time
typeset -F SECONDS=0

# ------------------------------------ compinit (deferred)
typeset -F __T1=$SECONDS
typeset -g ZCOMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "$(dirname "$ZCOMPDUMP")"

# Defer compinit until first tab completion for faster startup
typeset -g __compinit_loaded=0
__load_compinit() {
  if (( __compinit_loaded == 0 )); then
    __compinit_loaded=1
    typeset -F __TCOMP1=$SECONDS
    autoload -Uz compinit
    # Regenerate cache if it's older than 24 hours
    # shellcheck disable=SC1009,SC1073,SC1072,SC1036
    if [[ -f "$ZCOMPDUMP" ]] && [[ $(find "$ZCOMPDUMP" -mtime -1 2>/dev/null) ]]; then
      compinit -C -d "$ZCOMPDUMP"
    else
      compinit -d "$ZCOMPDUMP"
      # Compile zcompdump for faster loading
      { zcompile "$ZCOMPDUMP" } &!
    fi
    # Compile zcompdump if it's not compiled or older than the source
    if [[ ! -f "${ZCOMPDUMP}.zwc" ]] || [[ "$ZCOMPDUMP" -nt "${ZCOMPDUMP}.zwc" ]]; then
      { zcompile "$ZCOMPDUMP" } &!
    fi
    typeset -F __TCOMP2=$SECONDS
    _profile "[deferred] compinit loaded: %.0fms\n" $(( (__TCOMP2 - __TCOMP1) * 1000 ))
  fi
}

# Load compinit on first tab press or after short delay
__lazy_compinit_tab() {
  __load_compinit
  zle expand-or-complete
}
zle -N __lazy_compinit_tab
bindkey '^I' __lazy_compinit_tab

# Also load after 1 second in background if not triggered yet
{ sleep 1 && [[ $__compinit_loaded == 0 ]] && __load_compinit } &!

typeset -F __T2=$SECONDS
_profile "compinit setup: %.0fms (deferred)\n" $(( (__T2 - __T1) * 1000 ))

autoload -Uz bracketed-paste-magic
zle -N bracketed-paste bracketed-paste-magic

# ------------------------------------ Key mappings
typeset -F __TK1=$SECONDS
typeset -A KEYS
KEYS=(
  [SHIFT_ENTER]='^[[13;2u'
  [LEFT_ARROW]='^[OD'
  [RIGHT_ARROW]='^[OC'
  [ALT_T]='\et'
  [CTRL_LEFT]='^[[1;5D'
  [CTRL_RIGHT]='^[[1;5C'
  [CTRL_TAB]='\e[9;5u'
  [CTRL_SHIFT_TAB]='\e[9;6u'
  [CTRL_E]='^E'
  [CTRL_A]='^A'
  [CTRL_U]='^U'
  [CTRL_J]='^J'
  [CTRL_K]='^K'
  [CTRL_BACKSPACE]='^[[27;5;127~'
  [CTRL_DELETE]='^[[3;5~'
  [UP_ARROW]='^[[A'
  [UP_ARROW_ALT]='^[OA'
  [DOWN_ARROW]='^[[B'
  [DOWN_ARROW_ALT]='^[OB'
  [TAB]='^I'
  [SHIFT_TAB]='^[[Z'
  [ESCAPE]='^['
  [CTRL_ENTER]='\x1b[13;5u'
  [CTRL_ENTER_ALT]='CSI 13 ; 5 u'
  [SHIFT_DELETE]='^[[3;2~'
  [SHIFT_SPACE]='\x1b[32;2u'
  [SHIFT_ESCAPE]='\u001b[27;2u'
  [SPACE]=' '
  [ENTER]='^M'
  [PAGE_UP]='^[[5~'
  [PAGE_DOWN]='^[[6~'
  [CTRL_V]='^V'
  [CTRL_W]='^W'
  [CTRL_Q]='^Q'
)
typeset -F __TK2=$SECONDS
_profile "keys: %.0fms\n" $(( (__TK2 - __TK1) * 1000 ))

# ------------------------------------ ZSH hooks
typeset -F __TH1=$SECONDS
autoload -Uz add-zsh-hook

# Starship option 'add_newline = true' has weird behavior
# Use the following code instead to add a newline before the prompt

__add_newline() {
  echo ""
}

# Use the precmd hook to execute the __add_newline function just before the prompt is displayed
add-zsh-hook precmd __add_newline
typeset -F __TH2=$SECONDS
_profile "hooks+newline: %.0fms\n" $(( (__TH2 - __TH1) * 1000 ))

# ------------------------------------ ENV variables
typeset -F __TE1=$SECONDS
[ -f "$NIX_OUT_SHELL/.config/shell/xdg.sh" ] && source "$NIX_OUT_SHELL/.config/shell/xdg.sh"
typeset -F __TE2=$SECONDS
[ -f "$NIX_OUT_SHELL/.config/shell/variables.sh" ] && source "$NIX_OUT_SHELL/.config/shell/variables.sh"
typeset -F __TE3=$SECONDS

# Cache dircolors output for faster loading
typeset -g DIRCOLORS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/dircolors.zsh"
if command -v dircolors >/dev/null 2>&1; then
  if [[ ! -f "$DIRCOLORS_CACHE" ]] || [[ $(find /usr/bin/dircolors -newer "$DIRCOLORS_CACHE" 2>/dev/null) ]]; then
    dircolors -b > "$DIRCOLORS_CACHE"
  fi
  source "$DIRCOLORS_CACHE"
fi

typeset -F __TE4=$SECONDS
_profile "xdg: %.0fms, variables: %.0fms, dircolors: %.0fms\n" \
  $(( (__TE2 - __TE1) * 1000 )) \
  $(( (__TE3 - __TE2) * 1000 )) \
  $(( (__TE4 - __TE3) * 1000 ))

typeset -F __TH1=$SECONDS
mkdir -p "$XDG_STATE_HOME/zsh"
HISTFILE="$XDG_STATE_HOME/zsh/history"
HISTSIZE=10000
SAVEHIST=10000
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY
export HISTORY_IGNORE="(! *)"
typeset -F __TH2=$SECONDS
_profile "history: %.0fms\n" $(( (__TH2 - __TH1) * 1000 ))

# source "$NIX_OUT_SHELL/.config/shell/scripts/ssh-agent.sh"
# source "$NIX_OUT_SHELL"/zsh-autosuggestions/share/zsh-autosuggestions/zsh-autosuggestions.zsh
typeset -F __TA1=$SECONDS
source "$NIX_OUT_SHELL"/share/zsh-autosuggestions/zsh-autosuggestions.zsh
typeset -F __TA2=$SECONDS
_profile "autosuggestions: %.0fms\n" $(( (__TA2 - __TA1) * 1000 ))
# source "$NIX_OUT_SHELL/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"

# zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/zcompcache"
# compinit -d "$XDG_CACHE_HOME/zsh/zcompdump-$ZSH_VERSION"

# ------------------------------------ Word characters
typeset -F __TW1=$SECONDS
autoload -U select-word-style
select-word-style bash
setopt GLOB_DOTS
KEYTIMEOUT=1
typeset -F __TW2=$SECONDS
_profile "word-style: %.0fms\n" $(( (__TW2 - __TW1) * 1000 ))

# ------------------------------------ Remove default aliases
unalias run-help 2>/dev/null
unalias which-command 2>/dev/null
unalias l 2>/dev/null
unalias ll 2>/dev/null
unalias ls 2>/dev/null

# ------------------------------------ Remove default bindings
bindkey -r "${KEYS[ESCAPE]}"
bindkey -r "${KEYS[CTRL_V]}"
bindkey -r "${KEYS[CTRL_W]}"
bindkey -r "${KEYS[CTRL_Q]}"

# ------------------------------------ Move
# bindkey "${KEYS[SHIFT_ENTER]}" accept-line
bindkey "${KEYS[LEFT_ARROW]}" backward-char
bindkey "${KEYS[RIGHT_ARROW]}" forward-char
bindkey "${KEYS[CTRL_LEFT]}" backward-word
bindkey "${KEYS[CTRL_RIGHT]}" forward-word
bindkey "${KEYS[CTRL_TAB]}" forward-word
bindkey "${KEYS[CTRL_SHIFT_TAB]}" backward-kill-word
bindkey "${KEYS[CTRL_E]}" end-of-line
bindkey "${KEYS[CTRL_A]}" beginning-of-line

# ------------------------------------ Kill
bindkey "${KEYS[CTRL_U]}" kill-buffer
bindkey "${KEYS[CTRL_J]}" backward-kill-line
bindkey "${KEYS[CTRL_K]}" kill-line
bindkey "${KEYS[CTRL_BACKSPACE]}" backward-kill-word
bindkey "${KEYS[CTRL_DELETE]}" kill-word

# ------------------------------------ Search history
bindkey "${KEYS[UP_ARROW_ALT]}" history-beginning-search-backward
bindkey "${KEYS[UP_ARROW]}" history-beginning-search-backward
bindkey "${KEYS[DOWN_ARROW]}" history-beginning-search-forward
bindkey "${KEYS[DOWN_ARROW_ALT]}" history-beginning-search-forward

# ------------------------------------ Complete
typeset -F __TC1=$SECONDS
zmodload zsh/complist

zstyle ':completion:*' matcher-list 'm:{[:lower:]}={[:upper:]}' 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*:*:*:*:descriptions' format '%F{245}%d%f'
# shellcheck disable=SC2296
zstyle ':completion:*:default' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' list-dirs-first true
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select interactive

# bindkey -M menuselect "${KEYS[TAB]}" vi-down-line-or-history
# bindkey -M menuselect "${KEYS[SHIFT_TAB]}" vi-up-line-or-history
bindkey -M menuselect "${KEYS[TAB]}" forward-char
bindkey -M menuselect "${KEYS[SHIFT_TAB]}" backward-char
bindkey -M menuselect "${KEYS[ESCAPE]}" send-break

setopt MENU_COMPLETE
typeset -F __TC2=$SECONDS
_profile "completion-setup: %.0fms\n" $(( (__TC2 - __TC1) * 1000 ))
# bindkey -v '^?' backward-delete-char

# zstyle ':completion:*' menu select
# bindkey '^I' complete-word
# bindkey '^[[Z' reverse-menu-complete

# ------------------------------------ zsh-autosuggestions
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#7f7f7f"

typeset -gA CUSTOM_SUGGESTIONS
CUSTOM_SUGGESTIONS=(
  [zd]="ouch decompress SOURCES.EXTENSION"
  [zc]="ouch compress SOURCES TARGET.EXTENSION"
  [zl]="ouch list TARGET --tree"
)

__autosuggest_execute() {
  if [[ -n "${CUSTOM_SUGGESTIONS[$BUFFER]}" ]]; then
    BUFFER="${CUSTOM_SUGGESTIONS[$BUFFER]}"
  elif [[ -n "$POSTDISPLAY" ]]; then
    zle autosuggest-accept
  fi
  zle accept-line
}

# zle -N __autosuggest_execute
bindkey "${KEYS[SHIFT_ENTER]}" accept-line

__autosuggest_accept() {
  if [[ -n "${CUSTOM_SUGGESTIONS[$BUFFER]}" ]]; then
    BUFFER="${CUSTOM_SUGGESTIONS[$BUFFER]}"
    zle autosuggest-clear
  elif [[ -n "$POSTDISPLAY" ]]; then
    zle autosuggest-accept
  fi
  BUFFER="$BUFFER "
  CURSOR=${#BUFFER}
  zle redisplay
}

# zle -N __autosuggest_accept
# bindkey "${KEYS[CTRL_ENTER]}" __autosuggest_accept

# ------------------------------------ zsh-autocomplete
# zstyle ':completion:*:*:*:*:descriptions' format '%F{245}%d%f'
# zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
# bindkey '\t' menu-select "$terminfo[kcbt]" menu-selected
# bindkey -M menuselect '\t' menu-complete "$terminfo[kcbt]" reverse-menu-complete
# bindkey -M menuselect '\r' .accept-line
# bindkey -M menuselect ' ' undo

typeset -F __TAL1=$SECONDS
[ -f "$NIX_OUT_SHELL/.config/shell/aliases.sh" ] && source "$NIX_OUT_SHELL/.config/shell/aliases.sh"
typeset -F __TAL2=$SECONDS
_profile "aliases: %.0fms\n" $(( (__TAL2 - __TAL1) * 1000 ))

# ------------------------------------ NVM
__load_nvm() {
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}
typeset -F __T3=$SECONDS
__load_nvm
typeset -F __T4=$SECONDS
_profile "nvm: %.0fms\n" $(( (__T4 - __T3) * 1000 ))

# ------------------------------------ Functions
__source_functions() {
  if [ -d "$NIX_OUT_SHELL/.config/shell/functions" ]; then
    for file in "$NIX_OUT_SHELL/.config/shell/functions"/*.sh; do
      # Compile function files in background if not already compiled
      if [[ ! -f "${file}.zwc" ]] || [[ "$file" -nt "${file}.zwc" ]]; then
        { zcompile "$file" } &!
      fi
      . "$file"
    done
  fi
}
typeset -F __TF1=$SECONDS
__source_functions
typeset -F __TF2=$SECONDS
_profile "functions: %.0fms\n" $(( (__TF2 - __TF1) * 1000 ))

__on_empty_buffer() {
  if [[ -n "$BUFFER" ]]; then
      eval "$2"
      return
  fi

  if eval "$1"; then
    for precmd_function in "${precmd_functions[@]}"; do
      "$precmd_function"
    done
  fi

  zle reset-prompt
}

__last_command_or_delete() { __on_empty_buffer "BUFFER=${history[$((HISTCMD-1))]}; zle accept-line" 'zle backward-delete-char'; }
zle -N __last_command_or_delete
bindkey "${KEYS[SHIFT_DELETE]}" __last_command_or_delete

__navi_or_space() { __on_empty_buffer _navi_widget; }
zle -N __navi_or_space
bindkey "${KEYS[SHIFT_SPACE]}" __navi_or_space

__ls_or_escape() { __on_empty_buffer 'echo ls; __ls'; }
# __ls_or_escape() { __on_empty_buffer 'echo; command ls --almost-all --color --width 90;' "LBUFFER+=' '; zle autosuggest-fetch"; }
zle -N __ls_or_escape
bindkey "${KEYS[ESCAPE]}" __ls_or_escape

__tmux_attach_session_() {
  BUFFER="__tmux_attach_session"
  zle accept-line
}
zle -N __tmux_attach_session_
bindkey "${KEYS[ALT_T]}" __tmux_attach_session_

# _zsh_autosuggest_strategy_custom() {
#   # suggestion=$(grep -h -m1 -E "^[^#%]*$(printf '%s' "$1" | sed 's/[]\[\^\$\.\*\{\}\(\)\\]/\\&/g')" ~/.config/navi/* | head -n 1)
#   # suggestion=$(navi --query "$1" --best-match --print) # navi does not support non-interactive mode https://github.com/denisidoro/navi/issues/808
# }

_zsh_autosuggest_strategy_custom() {
  emulate -L zsh

  local prefix="$1"

  [[ -n "$prefix" ]] || return

  # shellcheck disable=SC2296
  for key in "${(@k)CUSTOM_SUGGESTIONS[@]}"; do
    if [[ "$key" == "$prefix"* ]]; then
      suggestion="$key ${CUSTOM_SUGGESTIONS[$key]}"
      return
    fi
  done
}

__aliases_() {
    local output
    output=$(aliases-fzf -f ~/terminal/config/shell/functions/leader-aliases 2>/dev/null)
    if [[ -n $output ]]; then
        if [[ $output == *$'\n' ]]; then
            BUFFER=$output
            zle accept-line
            zle reset-prompt
        else
            BUFFER=$output
            zle end-of-line
            zle autosuggest-fetch
            zle reset-prompt
        fi
    fi
}

__aliases_or_space() { __on_empty_buffer "__aliases --prefix ' ' --file $NIX_OUT_SHELL/.config/shell/functions/leader-aliases" "LBUFFER+=' '; zle autosuggest-fetch"; }
# __aliases_or_space() { __aliases_; }
zle -N __aliases_or_space
bindkey "${KEYS[SPACE]}" __aliases_or_space

__aliases_or_enter() { __on_empty_buffer "__aliases --prefix '^M' --file $NIX_OUT_SHELL/.config/shell/functions/leader-aliases" 'zle accept-line'; }
zle -N __aliases_or_enter
bindkey "${KEYS[ENTER]}" __aliases_or_enter

ZSH_AUTOSUGGEST_STRATEGY=(custom history completion)

# Defer compdef calls until compinit is loaded
__deferred_compdefs() {
  # Only run if compinit has been loaded
  if (( __compinit_loaded == 1 )); then
    compdef _cd __cd 2>/dev/null # Use the built-in cd completion for the custom cd function
    compdef _cd __mkdir_cd 2>/dev/null
    compdef _files __chezmoi add 2>/dev/null
    compdef _files __cp 2>/dev/null
  fi
}

# Will be called after compinit loads via background timer or first tab
typeset -ga precmd_functions
precmd_functions+=(__deferred_compdefs)

__prevd_widget() { __prevd; zle reset-prompt; }
zle -N __prevd_widget
bindkey "${KEYS[PAGE_UP]}" __prevd_widget

__nextd_widget() { __nextd; zle reset-prompt; }
zle -N __nextd_widget
bindkey "${KEYS[PAGE_DOWN]}" __nextd_widget

# ------------------------------------ Plugins

# Load critical plugins immediately (needed for prompt/env)
typeset -F __T5=$SECONDS
if command -v starship >/dev/null 2>&1; then
  typeset -g STARSHIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/starship.zsh"
  typeset -g STARSHIP_BIN=$(command -v starship)
  if [[ ! -f "$STARSHIP_CACHE" ]] || [[ "$STARSHIP_BIN" -nt "$STARSHIP_CACHE" ]]; then
    starship init zsh > "$STARSHIP_CACHE"
  fi
  source "$STARSHIP_CACHE"
fi
typeset -F __T6=$SECONDS
_profile "starship: %.0fms\n" $(( (__T6 - __T5) * 1000 ))

typeset -F __T7=$SECONDS
if command -v direnv >/dev/null 2>&1; then
  typeset -g DIRENV_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/direnv.zsh"
  typeset -g DIRENV_BIN=$(command -v direnv)
  if [[ ! -f "$DIRENV_CACHE" ]] || [[ "$DIRENV_BIN" -nt "$DIRENV_CACHE" ]]; then
    direnv hook zsh > "$DIRENV_CACHE"
  fi
  source "$DIRENV_CACHE"
fi
typeset -F __T8=$SECONDS
_profile "direnv: %.0fms\n" $(( (__T8 - __T7) * 1000 ))

# # Load fzf completion immediately (needed for completions)
# [[ ${options[zle]} = on ]] && . "$(fzf-share)/completion.zsh"

# Defer non-critical plugins until first prompt
__load_deferred_plugins() {
  typeset -F __TD1=$SECONDS
  command -v navi >/dev/null 2>&1 && eval "$(navi widget zsh)"
  typeset -F __TD2=$SECONDS
  command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init --no-cmd zsh)"
  typeset -F __TD3=$SECONDS
  [[ ${options[zle]} = on ]] && . "$(fzf-share)/key-bindings.zsh"
  typeset -F __TD4=$SECONDS
  _profile "[deferred] navi: %.0fms, zoxide: %.0fms, fzf: %.0fms\n" \
    $(( (__TD2 - __TD1) * 1000 )) \
    $(( (__TD3 - __TD2) * 1000 )) \
    $(( (__TD4 - __TD3) * 1000 ))
  add-zsh-hook -d precmd __load_deferred_plugins
}
add-zsh-hook precmd __load_deferred_plugins

# __open_file_or_autosuggest() {
#   if [[ -z "$BUFFER" ]]; then
#     __open_file
#   else
#     # zle autosuggest-accept
#     zle fzf-completion
#   fi
#   zle reset-prompt
# }

# zle -N __open_file_or_autosuggest
# bindkey "${KEYS[TAB]}" __open_file_or_autosuggest

__ripgrep_or_menu_complete() { __on_empty_buffer __ripgrep 'zle menu-complete'; }
zle -N __ripgrep_or_menu_complete
bindkey "${KEYS[SHIFT_TAB]}" __ripgrep_or_menu_complete

__tab_handler() {
  # If in menu selection, move backward
  # if [[ -n "$MENUSELECT" ]]; then
  #   zle backward-char
  #   return
  # If not in menu and buffer is empty, run ripgrep
  if [[ -z "$BUFFER" ]]; then
    # __ripgrep
    # zle reset-prompt
    __open_file
    # return
  # If buffer has text, accept autosuggestion
  elif [[ -n "$POSTDISPLAY" ]]; then
    # zle autosuggest-accept
    __autosuggest_accept
  else
    __autosuggest_execute
  fi
  zle reset-prompt
}

zle -N __tab_handler
bindkey "${KEYS[TAB]}" __tab_handler

__ls_or_shift_escape() { __on_empty_buffer 'echo ls; command ls --format=long --all --human-readable --classify --color=auto --sort=time --time-style=long-iso'; }
zle -N __ls_or_shift_escape
bindkey "${KEYS[SHIFT_ESCAPE]}" __ls_or_shift_escape

# handle_interrupt() {
#     echo ''
# }
# trap 'handle_interrupt' SIGINT
# pass show GEMINI_API_KEY > /dev/null

# __alias_or_delete() { __on_empty_buffer __run_alias "zle backward-delete-char"; }
# zle -N __alias_or_delete
# bindkey '^[[3~' __alias_or_delete

# __yazi() { __on_empty_buffer "yazi < $TTY"; }
# zle -N __yazi
# bindkey '\x1b[27;2u' __yazi

# bindkey '^[' __yazi
# bindkey '\e' __yazi

# __tmux_copy_mode() { __on_empty_buffer "tmux copy-mode > /dev/null 2>&1"; }
# zle -N __tmux_copy_mode
# bindkey '^[' __tmux_copy_mode

# __history_or_delete() { __on_empty_buffer "zle fzf-history-widget && zle accept-line" "zle backward-delete-char"; }
# zle -N __history_or_delete
# bindkey '^?' __history_or_delete
# # bindkey '^[[3;2~' __history_or_delete

# __navi_custom_or_space() { __on_empty_buffer navi "LBUFFER+=' '; zle autosuggest-fetch"; }
# zle -N __navi_custom_or_space
# bindkey ' ' __navi_custom_or_space

# __leader() { __on_empty_buffer __leader_widget; }
# zle -N __leader
# bindkey '^[' __leader

# __ls_or_space() { __on_empty_buffer 'command ls --almost-all --color --width 90;' "LBUFFER+=' '; zle autosuggest-fetch"; }
# zle -N __ls_or_space
# bindkey ' ' __ls_or_space

# __leader_or_space() { __on_empty_buffer __leader_widget "LBUFFER+=' '; zle autosuggest-fetch"; }
# zle -N __leader_or_space
# bindkey ' ' __leader_or_space

# __leader_or_accept() { __on_empty_buffer __leader_widget 'zle accept-line'; }
# zle -N __leader_or_accept
# bindkey '^M' __leader_or_accept

# __ls() { __on_empty_buffer 'command ls --almost-all --color --width 90;' 'zle accept-line'; }
# zle -N __ls
# bindkey '^M' __ls

# __tmux_search() { __on_empty_buffer 'tmux copy-mode; tmux command-prompt -i -p "" "send -X search-forward-incremental \"%%%\""' LBUFFER+="/"; }
# zle -N __tmux_search
# bindkey '/' __tmux_search

# __clear_or_esc() { __on_empty_buffer 'clear -x'; }
# zle -N __clear_or_esc
# bindkey '^[' __clear_or_esc

# __history_or_esc() { __on_empty_buffer "zle fzf-history-widget && zle accept-line"; }
# zle -N __history_or_esc
# bindkey '\u001B[27;2u' __history_or_esc

# __navi_or_space() { __on_empty_buffer "navi --path ~/.local/share/navi/cheats" "LBUFFER+=' '; zle autosuggest-fetch"; }
# zle -N __navi_or_space
# bindkey '\x1b[32;2u' __navi_or_space

# __yazi() { __on_empty_buffer "yazi < $TTY"; }
# zle -N __yazi
# bindkey '^[' __yazi
# bindkey '\x1b[27;2u' __yazi

# __yazi() { __on_empty_buffer "__yazi_cd < $TTY"; }
# zle -N __yazi
# bindkey '^[' __yazi

# __git_widget() { __on_empty_buffer "__aliases --prefix g --file $NIX_OUT_SHELL/.config/shell/functions/git-aliases" 'LBUFFER+=g; zle reset-prompt; zle autosuggest-fetch'; }

# zle -N __git_widget
# bindkey 'g' __git_widget

# Display zsh load time
if (( PROFILE_ZSH )); then
  printf "Total: %.0fms\n" $(( SECONDS * 1000 ))
else
  printf "%.0fms\n" $(( SECONDS * 1000 ))
fi
