resource "github_repository" "terminal" {
  name = var.repository_name

  visibility    = "public"
  has_issues    = true
  has_projects  = true
  has_wiki      = false
  allow_forking = true

  # Squash-only merges; auto-merge required by dependabot-auto-merge.yml.
  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true
  allow_auto_merge       = true
  delete_branch_on_merge = true

  web_commit_signoff_required = false

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  lifecycle {
    prevent_destroy = true
    # description / topics / homepage_url are managed via the GitHub UI; ignore
    # changes so UI edits don't surface as drift on every `tf plan`.
    ignore_changes = [
      description,
      topics,
      homepage_url,
    ]
  }
}

# Dependabot alerts. The `vulnerability_alerts` arg on github_repository is
# deprecated in provider v6; the dedicated resource is the supported path.
resource "github_repository_vulnerability_alerts" "terminal" {
  repository = github_repository.terminal.name
  enabled    = true
}
