variable "hcloud_token" {
  description = "Hetzner Cloud API access token (can be supplied via SOPS or TF_VAR_hcloud_token)"
  type        = string
  sensitive   = true
  default     = null
}

variable "rcon_password" {
  description = "Authentication password for Minecraft RCON"
  type        = string
  sensitive   = true
  default     = null
}

variable "github_pat" {
  description = "Scoped Personal Access Token for triggering GitHub Actions stop workflow from VM watchdog"
  type        = string
  sensitive   = true
  default     = null
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) where the stop workflow is located"
  type        = string
  default     = "bumuellp/mine-your-own-bum"
}

variable "server_name" {
  description = "Server instance name"
  type        = string
  default     = "mine-your-own-bum"
}
