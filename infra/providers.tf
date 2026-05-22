provider "github" {
  owner = var.github_owner
  # Token comes from the GITHUB_TOKEN env var. The `infra` devshell wrapper
  # passes it via `env GITHUB_TOKEN=...` (sourced from `gh auth token`) so
  # local runs don't need a separate PAT.
}
