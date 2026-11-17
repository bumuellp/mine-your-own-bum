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

variable "auth_password" {
  description = "In-game authentication password or PIN interpolated into rcon_startup_commands (leave empty or 'none' to disable)"
  type        = string
  sensitive   = true
  default     = null
}

variable "cf_api_key" {
  description = "CurseForge API key for downloading curseforge_projects (can be supplied via SOPS or TF_VAR_cf_api_key)"
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_tunnel_token" {
  description = "Cloudflare Tunnel connector token for private Workers VPC access to mc-agent"
  type        = string
  sensitive   = true
  default     = null
}

variable "agent_shared_secret" {
  description = "Shared secret authenticating Discord Worker requests to mc-agent (X-Agent-Secret)"
  type        = string
  sensitive   = true
  default     = null
}

variable "discord_chat_webhook_url" {
  description = "Discord webhook URL for live in-game chat and join/leave bridging (#mc-chat)"
  type        = string
  sensitive   = true
  default     = null
}

variable "discord_command_webhook_url" {
  description = "Optional Discord webhook URL for boot ready announcements (#mc-commands)"
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
  default     = null
}

variable "server_name" {
  description = "Server instance name"
  type        = string
  default     = "mine-your-own-bum"
}

variable "server_type" {
  description = "Ephemeral Minecraft server type override (e.g. cax21, cax31, cpx31). Can be set via TF_VAR_server_type."
  type        = string
  default     = null
}

variable "state_encryption_passphrase" {
  description = "Passphrase used to encrypt and decrypt OpenTofu state and plan files client-side"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_encryption_passphrase) >= 16
    error_message = "The state encryption passphrase must be at least 16 characters long."
  }
}
