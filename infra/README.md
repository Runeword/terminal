# infra/

GitHub repository settings managed with OpenTofu.

## What this manages

- Repository visibility, features, security analysis (`repository.tf`)
- Actions permissions: allowed actions, SHA pinning, default token scope (`actions.tf`)
- Branch protection on `main` (`branch-protection.tf`)
- No secrets: see [Actions & Dependabot secrets](#actions--dependabot-secrets)

## Usage

The `infra` wrapper (defined in `devshells/infra.nix`) runs `tofu` against this
directory and injects `GITHUB_TOKEN` from `gh auth token`:

```sh
infra init           # first time, or after provider version bump
infra plan           # show drift
infra apply          # reconcile
infra state list     # what's under management
```

## First-time import

State starts empty, so an `apply` would try to *create* resources that already
exist and fail with HTTP 422 from GitHub. **Always import first** — do not run
`infra apply` against a fresh checkout until every resource is imported:

```sh
infra init
infra import github_repository.terminal terminal
infra import github_repository_vulnerability_alerts.terminal terminal
infra import github_actions_repository_permissions.terminal terminal
infra import github_workflow_repository_permissions.terminal terminal
infra import github_branch_protection.main terminal:main
infra plan           # expect "no changes" — confirms config matches reality
```

If `plan` shows diffs after import, decide per field whether to codify the
drift into the `.tf` or apply the `.tf` over it. Don't reflexively `apply` —
that would clobber settings that drifted intentionally via the UI.

## Actions & Dependabot secrets

CI fetches the private `Runeword/permeance` and `Runeword/claude-sandbox` flake
inputs with `PERMEANCE_TOKEN`, which exists twice: as an Actions secret (push
and PR runs) and as a Dependabot secret (runs triggered by Dependabot PRs get a
separate secret namespace, where `${{ secrets.PERMEANCE_TOKEN }}` would
otherwise expand to empty and every GitHub fetch 401).

**Neither is managed here.** OpenTofu writes every managed resource's
attributes to `terraform.tfstate` in plaintext, a secret's value included, and
the state goes wherever this directory is copied: a `path:` flake input, for
one, copies ignored files too, into the world-readable Nix store. `secrets.tf`
only holds the `removed` blocks that take the two secrets once managed here out
of state without deleting them on GitHub, and `lib/tests-unit.nix` fails if a
`github_*_secret` resource comes back.

Set or rotate the token with `gh`, which prompts for the value and keeps it
nowhere but GitHub:

```sh
gh secret set PERMEANCE_TOKEN --repo Runeword/terminal
gh secret set PERMEANCE_TOKEN --repo Runeword/terminal --app dependabot
```

Create the PAT in the GitHub UI (browser-only — GitHub doesn't expose PAT
creation via API). It needs read access to public repos (for nixpkgs /
flake-utils fetches) **and** to the private `Runeword/permeance` and
`Runeword/claude-sandbox`. A **classic PAT with `repo` scope** covers all of
them; a fine-grained PAT scoped only to the private repos would 401 on public
fetches because the `access-tokens` per-path scoping isn't reliable in the Nix
version shipped by `cachix/install-nix-action@v31` (Nix 2.34.7). `repo` scope
also grants write to every repository the owner can access, so on any exposure
revoke it at once: `POST https://api.github.com/credentials/revoke`
(unauthenticated, body `{"credentials": ["<token>"]}`) revokes a token by its
value.

## State

State is local (`infra/terraform.tfstate`) and gitignored. It holds no secret
as long as none is managed here (see above); keep it owner-only anyway —
`chmod 600 infra/terraform.tfstate*`.

Losing the state means redoing the import workflow above — tedious, not a
disaster.

To graduate to a remote backend (S3, HCP Terraform, etc.), add a `backend`
block to `versions.tf` and run `infra init -migrate-state`. A remote backend
is the prerequisite for any scheduled drift-detection job (see below).

## `prevent_destroy` semantics

`github_repository.terminal` has `lifecycle { prevent_destroy = true }`. This
blocks `tofu destroy` and any plan that would *delete* the resource. It does
**not** block:

- `infra apply` modifying the resource in place.
- `infra state rm github_repository.terminal` (just forgets it; the GitHub
  repo is untouched).
- A forced replacement triggered by changing an immutable attribute (e.g.
  `var.repository_name`). The plan will error rather than destroy + create;
  to actually rename, `state rm` first, rename in the `.tf`, then re-import.

## Drift detection

No scheduled `infra plan` runs today — local state means CI can't see it.
Once a remote backend is in place, a weekly Action (`infra plan
-detailed-exitcode`, fail on exit 2) is the usual path. Until then, run
`infra plan` manually after any GitHub-UI change.
