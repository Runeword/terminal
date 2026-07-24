variable "github_owner" {
  type        = string
  default     = "Runeword"
  description = "GitHub user or org that owns the repository."
}

variable "repository_name" {
  type        = string
  default     = "terminal"
  description = "Repository to manage."
}

variable "permeance_token" {
  type      = string
  sensitive = true
  # Classic PAT with `repo` scope — required to read BOTH the private
  # Runeword/permeance flake input and public repos (nixpkgs, flake-utils) from
  # CI. A fine-grained token scoped to permeance alone 401s on the public
  # fetches under the Nix in cachix/install-nix-action@v31 (see README.md,
  # "Actions & Dependabot secrets"). `repo` scope unavoidably also grants write
  # to every repo the owner can access, so treat this as high-value: supply it
  # via TF_VAR_permeance_token (never terraform.tfvars), and rotate on exposure.
  description = "Classic GitHub PAT, repo scope: reads private Runeword/permeance + public repos from CI. Supply via TF_VAR_permeance_token; stored as the PERMEANCE_TOKEN Actions/Dependabot secret."
}
