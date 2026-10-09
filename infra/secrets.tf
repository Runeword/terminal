# PERMEANCE_TOKEN, the Actions and the Dependabot secret CI fetches the private
# flake inputs with, is set with `gh secret set` (README.md), never here:
# OpenTofu writes every managed attribute to terraform.tfstate in plaintext, a
# secret's value included. These blocks take the two secrets that used to be
# managed here out of state, without deleting them on GitHub.
removed {
  from = github_actions_secret.permeance_token
  lifecycle {
    destroy = false
  }
}

removed {
  from = github_dependabot_secret.permeance_token
  lifecycle {
    destroy = false
  }
}
