resource "github_branch_protection" "main" {
  repository_id = github_repository.terminal.node_id
  pattern       = "main"

  enforce_admins          = false
  allows_deletions        = false
  allows_force_pushes     = false
  require_signed_commits  = false
  required_linear_history = false

  required_status_checks {
    strict   = true
    contexts = ["check"]
  }
}
