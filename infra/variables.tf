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
  type        = string
  sensitive   = true
  description = "Fine-grained PAT with Contents:read on Runeword/permeance. Set via TF_VAR_permeance_token; CI consumes it as the PERMEANCE_TOKEN secret."
}
