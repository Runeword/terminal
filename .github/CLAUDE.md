# GitHub settings and CI

## GitHub settings (`Runeword/admin`)

This repository's GitHub settings (merge buttons, the Actions allow-list and SHA pinning, branch protection on `main`) live in the private `Runeword/admin` repository with every other Runeword repository's: one OpenTofu map, local state, applied from a plain terminal. No secret is managed there: CI's `PERMEANCE_TOKEN` is set with `gh secret set PERMEANCE_TOKEN --repo Runeword/terminal`, and again with `--app dependabot` (that repository's README says why it is a classic `repo` PAT).

## CI (`.github/workflows/`)

`ci.yml`'s matrix fans into a stable-named `check` aggregate job — that name is the required-status context in branch protection (managed in `Runeword/admin`), so don't rename it. The private inputs' token reaches nix only through `NIX_CONFIG` in the steps that fetch them, never `/etc/nix/nix.conf`, which is world-readable to builds that run unsandboxed on macOS. Dependabot proposes a revision once it is 7 days old (`cooldown`), and `dependabot-auto-merge.yml` leaves an update that edits `flake.nix` (an input's ref, not just its lock) to a person.
