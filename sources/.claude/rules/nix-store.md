# Don't glob `/nix/store/*/…`

A glob whose `*` matches every store entry and is followed by more path,
like `/nix/store/*/bin/foo`, makes zsh (which runs your Bash commands)
use memory that grows with the square of the matches, and the store has
~184k entries. `/nix/store/*/bin/alacritty --version` once grew to
~31 GB, all of RAM and swap, and stalled the machine for five minutes.
The Bash timeout doesn't stop it: it moves the command to the
background, where it keeps growing.

To find a tool or its version, resolve it rather than search for it:

    readlink -f "$(command -v foo)"
    nix eval --raw "$COMMA_NIXPKGS_FLAKE#foo.version"

When you must search the store, keep the wildcard in the last component
or narrow the first one: `ls -d /nix/store/*-foo-*` and
`/nix/store/*-foo-*/bin/foo` only walk the few entries that match.
