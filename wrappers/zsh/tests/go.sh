# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# god and godc (go.bash): the Go dev builds in .direnv/bin that shadow the
# Nix copies.

# godc (and gow when it stops) clears the Go dev builds that shadow the
# Nix copies: every compiled binary in .direnv/bin, not nix-direnv's script.
bin=$HOME/terminal/.direnv/bin
mkdir -p "$bin"
printf '\177ELF' >"$bin/stale"
printf '#!/bin/sh\n' >"$bin/nix-direnv-reload"
@zsh@/bin/zsh -f -c '. @zsh@/.config/shell/functions/go.bash; __go_dev clean' >/dev/null
if [ ! -e "$bin/stale" ] && [ -e "$bin/nix-direnv-reload" ]; then
  ok "godc clears compiled dev builds and keeps nix-direnv-reload"
else
  fail "godc does not clear exactly the compiled dev builds"
fi

# god names each dev build after its go.mod module, not its directory
# (packages/git/branches builds git-branches); a stub go records it.
mkdir -p "$HOME/terminal/packages/grp/tool" "$HOME/stub"
printf 'module grp-tool\n' >"$HOME/terminal/packages/grp/tool/go.mod"
printf '#!/bin/sh\n: > "$3"\n' >"$HOME/stub/go"
chmod +x "$HOME/stub/go"
PATH=$HOME/stub:$PATH @zsh@/bin/zsh -f -c '. @zsh@/.config/shell/functions/go.bash; __go_dev' >/dev/null
if [ -e "$bin/grp-tool" ] && [ ! -e "$bin/tool" ]; then
  ok "god names dev builds after their go.mod module"
else
  fail "god does not name dev builds after their go.mod module"
fi
