# infra/

GitHub repository settings managed with OpenTofu.

## What this manages

- Repository visibility, features, security analysis (`repository.tf`)
- Actions permissions: allowed actions, SHA pinning, default token scope (`actions.tf`)
- Branch protection on `main` (`branch-protection.tf`)
- Actions secrets (`secrets.tf`) — currently `PERMEANCE_TOKEN`, used by `.github/workflows/ci.yml` to fetch the private `Runeword/permeance` flake input

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

`secrets.tf` provisions `PERMEANCE_TOKEN` twice — once as a
`github_actions_secret` (for push/PR runs) and once as a
`github_dependabot_secret` (for runs triggered by Dependabot PRs, which run
with a separate secret namespace). Both pull the value from
`var.permeance_token`. Create the PAT in the GitHub UI (browser-only — GitHub
doesn't expose PAT creation via API), then feed it to OpenTofu via env:

```sh
TF_VAR_permeance_token='<pat>' infra apply
```

The PAT needs read access to public repos (for nixpkgs / flake-utils fetches)
**and** to `Runeword/permeance`. A **classic PAT with `repo` scope** satisfies
both; a fine-grained PAT scoped only to `Runeword/permeance` would 401 on
public fetches because the `access-tokens` per-path scoping isn't reliable in
the Nix version shipped by `cachix/install-nix-action@v31` (Nix 2.34.7).

The plaintext value lands in local `terraform.tfstate` (gitignored). If the
secret already exists in GitHub (e.g. you ran `gh secret set` first), import
before applying: `infra import github_actions_secret.permeance_token
terminal/PERMEANCE_TOKEN`. Import only restores metadata — the next `apply`
will overwrite the value with whatever `TF_VAR_permeance_token` resolves to.

## State

State is local (`infra/terraform.tfstate`) and gitignored. It contains no
secrets for the resources currently managed here. Losing it means redoing the
import workflow above — not a disaster, but tedious. Back it up somewhere
recoverable, e.g.:

```sh
cp infra/terraform.tfstate ~/Backups/terminal-tfstate.$(date +%F)
# or attach to a password-manager entry / encrypted USB
```

To graduate to a remote backend (S3, HCP Terraform, etc.), add a `backend`
block to `versions.tf` and run `infra init -migrate-state`. A remote backend
is also the prerequisite for any scheduled drift-detection job (see below).

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
