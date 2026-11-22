terraform {
  required_version = ">= 1.8.0"
}

variable "cf_api_key" {
  description = "Optional CurseForge API key decrypted in CI for active modpack smoke testing"
  type        = string
  default     = "smoke-test-cf-key"
}

locals {
  baseline_settings = yamldecode(file("${path.module}/../../config/settings.example.yaml"))
  active_settings   = yamldecode(file(fileexists("${path.module}/../../config/settings.yaml") ? "${path.module}/../../config/settings.yaml" : "${path.module}/../../config/settings.example.yaml"))

  docker_compose = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type                 = local.baseline_settings.minecraft.server_type
    minecraft_version           = local.baseline_settings.minecraft.version
    jvm_memory                  = "2G"
    mc_mem_limit                = "3728m"
    motd                        = local.baseline_settings.minecraft.motd
    max_players                 = local.baseline_settings.minecraft.max_players
    difficulty                  = local.baseline_settings.minecraft.difficulty
    online_mode                 = local.baseline_settings.minecraft.online_mode
    enforce_secure_profile      = local.baseline_settings.minecraft.enforce_secure_profile
    whitelist_enabled           = local.baseline_settings.minecraft.whitelist_enabled
    whitelist                   = local.baseline_settings.minecraft.whitelist
    ops                         = local.baseline_settings.minecraft.ops
    rcon_password               = "smoke-test-rcon-secret"
    minecraft_image             = local.baseline_settings.containers.minecraft_server
    backup_image                = local.baseline_settings.containers.backup
    mc_agent_image              = local.baseline_settings.containers.mc_agent
    cloudflared_image           = local.baseline_settings.containers.cloudflared
    cloudflare_tunnel_token     = ""
    agent_shared_secret         = ""
    discord_chat_webhook_url    = ""
    discord_command_webhook_url = ""
    server_fqdn                 = ""
    server_location             = local.baseline_settings.server.location
    modrinth_modpack            = ""
    modrinth_exclude_files      = []
    modrinth_projects           = local.baseline_settings.minecraft.modrinth_projects
    curseforge_projects         = []
    cf_api_key                  = ""
    rcon_startup_commands       = ["say Smoke test startup RCON command verified"]
    plugins                     = local.baseline_settings.minecraft.plugins
    backup_enabled              = local.baseline_settings.backup.enabled
    backup_interval             = local.baseline_settings.backup.interval
    backup_initial_delay        = local.baseline_settings.backup.initial_delay
    backup_retention_count      = local.baseline_settings.backup.retention_count
    backup_s3_bucket            = "smoke-test-bucket"
    backup_s3_endpoint          = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider          = "Cloudflare"
    backup_s3_access_key        = "dummy-access-key"
    backup_s3_secret_key        = "dummy-secret-key"
  })

  # 1. Active repository configuration rendered as-is (clamped to 4G JVM memory for 7GB GitHub runners)
  docker_compose_active = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type                 = local.active_settings.minecraft.server_type
    minecraft_version           = local.active_settings.minecraft.version
    jvm_memory                  = "4G"
    mc_mem_limit                = "5776m"
    motd                        = local.active_settings.minecraft.motd
    max_players                 = local.active_settings.minecraft.max_players
    difficulty                  = local.active_settings.minecraft.difficulty
    online_mode                 = local.active_settings.minecraft.online_mode
    enforce_secure_profile      = local.active_settings.minecraft.enforce_secure_profile
    whitelist_enabled           = local.active_settings.minecraft.whitelist_enabled
    whitelist                   = try(local.active_settings.minecraft.whitelist, [])
    ops                         = try(local.active_settings.minecraft.ops, [])
    rcon_password               = "smoke-test-rcon-secret"
    minecraft_image             = local.active_settings.containers.minecraft_server
    backup_image                = local.active_settings.containers.backup
    mc_agent_image              = try(local.active_settings.containers.mc_agent, "ghcr.io/bumuellp/mc-agent:0.1.0")
    cloudflared_image           = try(local.active_settings.containers.cloudflared, "cloudflare/cloudflared:2026.3.0")
    cloudflare_tunnel_token     = ""
    agent_shared_secret         = ""
    discord_chat_webhook_url    = ""
    discord_command_webhook_url = ""
    server_fqdn                 = ""
    server_location             = local.active_settings.server.location
    modrinth_modpack            = try(trimspace(local.active_settings.minecraft.modrinth_modpack), "")
    modrinth_exclude_files      = try(local.active_settings.minecraft.modrinth_exclude_files, [])
    modrinth_projects           = try(local.active_settings.minecraft.modrinth_projects, [])
    curseforge_projects         = var.cf_api_key != "" && var.cf_api_key != "smoke-test-cf-key" ? try(local.active_settings.minecraft.curseforge_projects, []) : []
    cf_api_key                  = var.cf_api_key
    rcon_startup_commands       = try(local.active_settings.minecraft.rcon_startup_commands, [])
    plugins                     = try(local.active_settings.minecraft.plugins, [])
    backup_enabled              = local.active_settings.backup.enabled
    backup_interval             = local.active_settings.backup.interval
    backup_initial_delay        = local.active_settings.backup.initial_delay
    backup_retention_count      = local.active_settings.backup.retention_count
    backup_s3_bucket            = "smoke-test-bucket"
    backup_s3_endpoint          = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider          = "Cloudflare"
    backup_s3_access_key        = "dummy-access-key"
    backup_s3_secret_key        = "dummy-secret-key"
  })

  # 2. Self-contained synthetic fixture exercising all optional template branches (modpack, CurseForge, sidecars, $-escaping) for YAML syntax verification
  docker_compose_modpack = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type                 = "MODRINTH"
    minecraft_version           = "1.21.1"
    jvm_memory                  = "4G"
    mc_mem_limit                = "5776m"
    motd                        = "Smoke Test Synthetic Matrix"
    max_players                 = 10
    difficulty                  = "normal"
    online_mode                 = true
    enforce_secure_profile      = true
    whitelist_enabled           = true
    whitelist                   = ["Steve"]
    ops                         = ["Steve"]
    rcon_password               = "smoke-test-rcon-secret"
    minecraft_image             = local.baseline_settings.containers.minecraft_server
    backup_image                = local.baseline_settings.containers.backup
    mc_agent_image              = local.baseline_settings.containers.mc_agent
    cloudflared_image           = local.baseline_settings.containers.cloudflared
    cloudflare_tunnel_token     = "smoke-test-tunnel-$token"
    agent_shared_secret         = "smoke-test-agent-$secret-32-chars-ok"
    discord_chat_webhook_url    = "https://discord.com/api/webhooks/000/chat"
    discord_command_webhook_url = "https://discord.com/api/webhooks/000/cmd"
    server_fqdn                 = "mc.example.com"
    server_location             = "fsn1"
    modrinth_modpack            = "example-modpack:beta"
    modrinth_exclude_files      = ["raised"]
    modrinth_projects           = ["example-mod"]
    curseforge_projects         = ["example-curseforge-mod"]
    cf_api_key                  = "smoke-test-cf-$secret-key"
    rcon_startup_commands       = ["say Smoke test $secret escaping"]
    plugins                     = []
    backup_enabled              = true
    backup_interval             = "1h"
    backup_initial_delay        = "5m"
    backup_retention_count      = 5
    backup_s3_bucket            = "smoke-test-bucket"
    backup_s3_endpoint          = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider          = "Cloudflare"
    backup_s3_access_key        = "dummy-access-key"
    backup_s3_secret_key        = "dummy-secret-key"
  })

  cloud_init = templatefile("${path.module}/../../iac/templates/cloud-init.yaml.tftpl", {
    always_on              = local.active_settings.server.always_on
    idle_timeout           = local.active_settings.server.idle_timeout_minutes
    github_repository      = "example-owner/example-repo"
    github_pat             = "smoke-test-github-pat"
    github_api_version     = trimspace(file("${path.module}/../../.github-api-version"))
    keyboard_layout        = local.active_settings.server.keyboard_layout
    console_password       = "smoke-test-console-secret"
    volume_id              = "12345678"
    docker_compose         = local.docker_compose
    modrinth_exclude_files = try(local.active_settings.minecraft.modrinth_exclude_files, [])
    watchdog_script        = file("${path.module}/../../iac/files/scripts/idle-watchdog.sh")
    bootstrap_script       = file("${path.module}/../../iac/files/scripts/bootstrap-volume.sh")
    prune_script           = file("${path.module}/../../iac/files/scripts/prune-rclone-backups.sh")
    systemd_service        = file("${path.module}/../../iac/files/systemd/mc-idle-watchdog.service")
    systemd_timer          = file("${path.module}/../../iac/files/systemd/mc-idle-watchdog.timer")
  })
}

output "docker_compose" {
  value = local.docker_compose
}

output "docker_compose_active" {
  value = local.docker_compose_active
}

output "docker_compose_modpack" {
  value = local.docker_compose_modpack
}

output "cloud_init" {
  value = local.cloud_init
}
