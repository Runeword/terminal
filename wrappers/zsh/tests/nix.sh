# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# hgr, ngr, na, dr, hs and fc (nix.sh).

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

# fc (__flake_run_commit) runs a flake at the commit picked in fzf, with
# what follows the flake handed to its app. In a repository, its commits
# are read from it, and nix run gets a git+file: URL at the commit picked,
# its flake found as nix run finds it, up from the directory, under dir=
# when it is below the top. A URL's commits come from a clone, made in the
# runtime dir and removed once one is picked or none is, and nix run gets
# the URL at that commit, its other parameters and #fragment kept. Escape
# in the picker runs nothing, nor does a flake whose commits can't be
# listed. A real git and repository, with a flake at its top and one in
# sub/; stand-ins: fzf picks the older of its two commits, or leaves with
# escape's status when FCESC is set, nix prints what it was handed, and
# git clone records what it was asked and clones that repository instead.
fcrepo=$(cd "$TMPDIR" && pwd -P)/fcrepo
mkdir -p "$fcrepo/sub/deep" "$fcrepo/deep/er" "$TMPDIR/fcrun" "$TMPDIR/fcnone"
fcgit() { @git@/bin/git -C "$fcrepo" -c user.name=t -c user.email=t@example.com "$@"; }
fcgit init -q -b main
echo '{ }' >"$fcrepo/flake.nix"
echo '{ }' >"$fcrepo/sub/flake.nix"
touch "$fcrepo/deep/er/.keep" "$fcrepo/sub/deep/.keep"
fcgit add -A
fcgit commit -q -m older
fcgit commit -q --allow-empty -m newer
older=$(fcgit rev-parse HEAD~1)
fc='. @zsh@/.config/shell/functions/nix.sh
  fzf() { [ -n "$FCESC" ] && return 130; grep older | cut -f1; }
  nix() { printf "[%s]" "$@"; }
  git() { if [ "$1" = clone ]; then print -r -- "$*" >"$TMPDIR/fcclone"; command git clone -q --bare "$FCREPO" "${@[-1]}"; else command git "$@"; fi; }
  __flake_run_commit "$@"'
# fcrun DIR [ARG...]: runs $fc in zsh from DIR, ARG... for
# __flake_run_commit, with the real git on PATH; its stderr goes to
# $TMPDIR/fc.err.
fcrun() {
  (
    cd "$1" || exit 1
    shift
    env FCREPO="$fcrepo" FCESC="${FCESC-}" XDG_RUNTIME_DIR="$TMPDIR/fcrun" PATH="@git@/bin:$PATH" \
      @zsh@/bin/zsh -f -c "$fc" zsh "$@" 2>"$TMPDIR/fc.err"
  )
}
if fcout=$(fcrun "$fcrepo/deep/er") &&
  [ "$fcout" = "[run][git+file://$fcrepo?rev=$older]" ] &&
  [ "$(cat "$TMPDIR/fc.err")" = "nix run 'git+file://$fcrepo?rev=$older'" ]; then
  ok "fc in a repository runs its flake, found up from the directory, at the commit picked, and says what it runs"
else
  fail "fc in a repository does not run its flake at the commit picked: $fcout $(cat "$TMPDIR/fc.err")"
fi
if fcout=$(fcrun "$fcrepo" ./sub/deep --flag "a b") &&
  [ "$fcout" = "[run][git+file://$fcrepo?dir=sub&rev=$older][--][--flag][a b]" ]; then
  ok "fc on a path below the top runs the flake there, under dir=, and hands its app what follows"
else
  fail "fc on a path below the top does not run the flake there with its arguments: $fcout $(cat "$TMPDIR/fc.err")"
fi
if fcout=$(fcrun "$TMPDIR/fcnone" 'github:owner/name/dev?dir=sub#app' --flag) &&
  [ "$fcout" = "[run][github:owner/name/$older?dir=sub#app][--][--flag]" ] &&
  case $(cat "$TMPDIR/fcclone") in *" --branch=dev -- https://github.com/owner/name $TMPDIR/fcrun/flake-commits."*) true ;; *) false ;; esac &&
  [ -z "$(ls -A "$TMPDIR/fcrun")" ]; then
  ok "fc on a github: URL lists its ref's commits from a clone it removes, then runs the URL at the commit picked, its dir= and #fragment kept"
else
  fail "fc on a github: URL does not run it at the commit picked: $fcout $(cat "$TMPDIR/fcclone" "$TMPDIR/fc.err")"
fi
if fcout=$(fcrun "$TMPDIR/fcnone" 'git+ssh://git@example.com/o/r?ref=main&shallow=1') &&
  [ "$fcout" = "[run][git+ssh://git@example.com/o/r?shallow=1&ref=main&rev=$older]" ] &&
  case $(cat "$TMPDIR/fcclone") in *" --branch=main -- ssh://git@example.com/o/r $TMPDIR/fcrun/"*) true ;; *) false ;; esac then
  ok "fc on a git+ssh: URL clones its ref over ssh and runs the URL at the commit picked, its parameters kept"
else
  fail "fc on a git+ssh: URL does not run it at the commit picked: $fcout $(cat "$TMPDIR/fcclone" "$TMPDIR/fc.err")"
fi
if fcout=$(FCESC=1 fcrun "$TMPDIR/fcnone" github:owner/name) && [ -z "$fcout" ] &&
  [ -z "$(ls -A "$TMPDIR/fcrun")" ]; then
  ok "escape in fc's picker runs nothing and removes the clone"
else
  fail "fc runs something after escape in its picker, or leaves its clone: $fcout $(ls -A "$TMPDIR/fcrun")"
fi
if fcout=$(fcrun "$TMPDIR/fcnone" nixpkgs); then
  fail "fc runs a flake whose commits it can't list: $fcout"
elif [ -z "$fcout" ] &&
  [ "$(cat "$TMPDIR/fc.err")" = "flake: can't list the commits of nixpkgs: give a path, a github:, gitlab: or sourcehut: URL, or a git+ one" ]; then
  ok "fc runs nothing, and says why, for a flake whose commits it can't list"
else
  fail "fc does not say why it can't list a flake's commits: $(cat "$TMPDIR/fc.err")"
fi
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^fc +$/ && $5 == "__flake_run_commit #LINE" && $6 == "run" { found = 1 } END { exit !found }'; then
  ok "the bundled leader.conf runs __flake_run_commit on the typed line with fc"
else
  fail "the bundled leader.conf does not run __flake_run_commit on the typed line with fc"
fi
