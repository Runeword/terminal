# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# hgr, ngr, na, dr and hs (nix.sh).

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# hgr leaves the current home-manager generation out of its list, as
# ngr does below: home-manager refuses to remove it. A stand-in fzf
# records the list.
hm_generations='. @zsh@/.config/shell/functions/nix.sh
  home-manager() { print -l "2026-01-02 00:00 : id 2 -> /nix/store/b (current)" "2026-01-01 00:00 : id 1 -> /nix/store/a"; }
  fzf() { cat > "$HOME/offered-hm"; }
  __home_manager_generation_remove'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^hgr +$/ && $5 == "__home_manager_generation_remove" && $6 == "run" { found = 1 } END { exit !found }' &&
  {
    @zsh@/bin/zsh -f -c "$hm_generations"
    [ "$(awk '{ print $5 }' "$HOME/offered-hm")" = 1 ]
  }; then
  ok "hgr lists every home-manager generation but the current one"
else
  fail "hgr lists the current home-manager generation, which home-manager refuses to remove"
fi

# ngr leaves the current NixOS generation out of its list: nix-env
# refuses a list that names it and removes none of the others, so
# select-all would remove nothing. A stand-in fzf records the list.
nixos_generations='. @zsh@/.config/shell/functions/nix.sh
  sudo() { "$@"; }
  nix-env() { print -l " 1   2026-01-01 00:00:00   " " 2   2026-01-02 00:00:00   (current)"; }
  fzf() { cat > "$HOME/offered"; }
  __nixos_generation_remove'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^ngr +$/ && $5 == "__nixos_generation_remove" && $6 == "run" { found = 1 } END { exit !found }' &&
  {
    @zsh@/bin/zsh -f -c "$nixos_generations"
    [ "$(awk '{ print $1 }' "$HOME/offered")" = 1 ]
  }; then
  ok "ngr lists every NixOS generation but the current one"
else
  fail "ngr lists the current NixOS generation, which nix-env refuses to delete"
fi

# na does hd and nd in one, then refreshes the boot menu as ngr does:
# the home-manager profile goes first, as the user, since root's
# nix-collect-garbage never sees it. Stand-ins print each command.
clean_all='. @zsh@/.config/shell/functions/nix.sh
  XDG_STATE_HOME=/state
  nix-env() { print -rn -- "nix-env $*; "; }
  sudo() { print -rn -- "sudo $*; "; }
  __nix_garbage_clean_all'
cleaned="nix-env -p /state/nix/profiles/home-manager --delete-generations old; "
cleaned+="sudo nix-collect-garbage --verbose --delete-old; "
cleaned+="sudo /run/current-system/bin/switch-to-configuration boot; "
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^na +$/ && $5 == "__nix_garbage_clean_all" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(@zsh@/bin/zsh -f -c "$clean_all")" = "$cleaned" ]; then
  ok "na deletes the old home-manager generations, then root's, collects the garbage and refreshes the boot menu"
else
  fail "na does not delete the old home-manager and NixOS generations, collect the garbage and refresh the boot menu"
fi

# dr reloads direnv with nix-direnv's own script where its environment
# put it on PATH, as direnvrc's manual-reload mode leaves a flake's
# cached devshell to it, and with direnv reload anywhere else.
# Stand-ins print which one ran.
mkdir -p "$HOME/direnv/bin"
printf '#!/bin/sh\necho nix-direnv-reload\n' >"$HOME/direnv/bin/nix-direnv-reload"
chmod +x "$HOME/direnv/bin/nix-direnv-reload"
reload='. @zsh@/.config/shell/functions/nix.sh
  direnv() { print -r -- "direnv $*"; }
  __direnv_reload'
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^dr +$/ && $5 == "__direnv_reload" && $6 == "run" { found = 1 } END { exit !found }' &&
  [ "$(PATH=$HOME/direnv/bin:$PATH @zsh@/bin/zsh -f -c "$reload")" = nix-direnv-reload ] &&
  [ "$(@zsh@/bin/zsh -f -c "$reload")" = "direnv reload" ]; then
  ok "dr runs nix-direnv-reload where nix-direnv put it on PATH, and direnv reload anywhere else"
else
  fail "dr does not run nix-direnv-reload where nix-direnv put it on PATH, or direnv reload anywhere else"
fi

# hs (__home_manager_switch) refreshes the home-manager flake's local
# inputs before switching: path: ones and git+file: ones, never remote
# ones. A stand-in nix answers the metadata query and prints each input
# it is asked to update.
printf '%s' '{"locks":{"nodes":{"root":{"inputs":{"f":"f","n":"n","t":"t"}},"f":{"locked":{"type":"git","url":"file:///f","ref":"main"}},"n":{"locked":{"type":"git","url":"https://n"}},"t":{"locked":{"type":"path","path":"/t"}}}}}' >"$HOME/hm.json"
hmswitch='. @zsh@/.config/shell/functions/nix.sh
  nix() { case "$2" in metadata) cat "$HOME/hm.json" ;; update) printf "%s\n" "$5" ;; esac; }
  home-manager() { :; }
  __home_manager_switch'
if [ "$(PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$hmswitch")" = "$(printf 'f\nt')" ]; then
  ok "hs refreshes the home-manager flake's local path: and git+file: inputs, not remote ones"
else
  fail "hs does not refresh exactly the home-manager flake's local inputs"
fi
