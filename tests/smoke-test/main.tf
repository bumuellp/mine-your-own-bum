terraform {
  required_version = ">= 1.8.0"
}

locals {
  settings = yamldecode(file(fileexists("${path.module}/../../config/settings.yaml") ? "${path.module}/../../config/settings.yaml" : "${path.module}/../../config/settings.example.yaml"))
}

output "docker_compose" {
  value = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type            = local.settings.minecraft.server_type
    minecraft_version      = local.settings.minecraft.version
    jvm_memory             = "2G"
    motd                   = local.settings.minecraft.motd
    max_players            = local.settings.minecraft.max_players
    difficulty             = local.settings.minecraft.difficulty
    whitelist_enabled      = false
    whitelist              = []
    ops                    = []
    rcon_password          = "smoke-test-rcon-secret"
    modrinth_projects      = local.settings.minecraft.modrinth_projects
    plugins                = local.settings.minecraft.plugins
    backup_enabled         = local.settings.backup.enabled
    backup_interval        = local.settings.backup.interval
    backup_initial_delay   = local.settings.backup.initial_delay
    backup_retention_count = local.settings.backup.retention_count
    backup_s3_bucket       = "smoke-test-bucket"
    backup_s3_endpoint     = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider     = "Cloudflare"
    backup_s3_access_key   = "dummy-access-key"
    backup_s3_secret_key   = "dummy-secret-key"
  })
}
