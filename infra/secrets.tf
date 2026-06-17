resource "github_actions_secret" "permeance_token" {
  repository  = github_repository.terminal.name
  secret_name = "PERMEANCE_TOKEN"
  value       = var.permeance_token
}
