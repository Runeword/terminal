# GitHub settings and CI

## GitHub settings (`Runeword/admin`)

This repository's GitHub settings (merge buttons, the Actions allow-list and SHA pinning, branch protection on `main`) live in the private `Runeword/admin` repository with every other Runeword repository's: one OpenTofu map, local state, applied from a plain terminal. No secret is managed there. CI reads the three private flake inputs as a GitHub App installed on those repositories alone, with read-only access to their contents: its client ID and private key are the secrets `INPUTS_APP_CLIENT_ID` and `INPUTS_APP_PRIVATE_KEY`, each set with `gh secret set <name> --repo Runeword/terminal` and again with `--app dependabot`.

## CI (`.github/workflows/`)

`ci.yml`'s matrix fans into a stable-named `check` aggregate job — that name is the required-status context in branch protection (managed in `Runeword/admin`), so don't rename it. `actions/create-github-app-token` mints the App's token for each job, and it reaches git only through the `GIT_CONFIG_*` variables of the steps that fetch the private inputs: a rule that rewrites their `ssh://` addresses to https with the token. It is never written to a file, least of all `/etc/nix/nix.conf`, which is world-readable to builds that run unsandboxed on macOS (install-nix-action already writes the job's own `GITHUB_TOKEN` there, which nix uses for public GitHub fetches). Dependabot proposes a revision once it is 7 days old (`cooldown`). `dependabot-auto-merge.yml` runs the merge steps shared with the other repositories, from `Runeword/workflows` pinned to a release: they leave a major version, or an update that edits `flake.nix` (an input's ref, not just its lock), to a person.
