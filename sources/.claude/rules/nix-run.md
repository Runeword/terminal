# Tools that aren't installed: run them with Nix

When a command is not found, don't install it: no `nix profile install`,
`nix-env -i`, `apt`, `brew`, `pip install`, `npm i -g`, `cargo install`,
`go install`, or `curl … | sh`. Run it for that one invocation from nixpkgs:

    nix shell "$COMMA_NIXPKGS_FLAKE#<attr>" --command <cmd> [args…]

`$COMMA_NIXPKGS_FLAKE` is the terminal's pinned nixpkgs, already in the
store: it resolves without a download, to the same builds as the terminal's
own tools. Prefer it to `nixpkgs#`, which goes through the host's registry.
For several tools at once, list several installables before `--command`.

If you don't know the attribute, look it up offline first: `, -p <cmd>`
lists the packages that ship `bin/<cmd>`; use the attribute as printed
(`jq.bin`). Don't run through `, <cmd>` itself: it needs a terminal to pick
between packages, and it ignores the pin wherever NIX_PATH sets nixpkgs.

This is for missing commands only, never a way around one that is present
but gated (a permission prompt, the git allowlist). If a tool keeps coming
back, suggest adding it to the flake instead.
