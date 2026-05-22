resource "github_actions_repository_permissions" "terminal" {
  repository           = github_repository.terminal.name
  allowed_actions      = "selected"
  sha_pinning_required = true

  allowed_actions_config {
    github_owned_allowed = true
    verified_allowed     = true
    patterns_allowed     = ["cachix/*", "dependabot/*"]
  }
}

resource "github_workflow_repository_permissions" "terminal" {
  repository                       = github_repository.terminal.name
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}
