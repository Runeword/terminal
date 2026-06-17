resource "github_actions_secret" "permeance_token" {
  repository  = github_repository.terminal.name
  secret_name = "PERMEANCE_TOKEN"
  value       = var.permeance_token
}

# Dependabot's PR workflows run with a separate secrets namespace from Actions.
# Without this, ${{ secrets.PERMEANCE_TOKEN }} expands to empty in dependabot
# PR runs and `nix flake check` 401s on every GitHub fetch.
resource "github_dependabot_secret" "permeance_token" {
  repository  = github_repository.terminal.name
  secret_name = "PERMEANCE_TOKEN"
  value       = var.permeance_token
}
