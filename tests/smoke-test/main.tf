terraform {
  required_version = ">= 1.8.0"
}

locals {
  baseline_settings = yamldecode(file("${path.module}/../../config/settings.example.yaml"))
  active_settings   = yamldecode(file(fileexists("${path.module}/../../config/settings.yaml") ? "${path.module}/../../config/settings.yaml" : "${path.module}/../../config/settings.example.yaml"))

  docker_compose = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type            = local.baseline_settings.minecraft.server_type
    minecraft_version      = local.baseline_settings.minecraft.version
    jvm_memory             = "2G"
    motd                   = local.baseline_settings.minecraft.motd
    max_players            = local.baseline_settings.minecraft.max_players
    difficulty             = local.baseline_settings.minecraft.difficulty
    online_mode            = local.baseline_settings.minecraft.online_mode
    enforce_secure_profile = local.baseline_settings.minecraft.enforce_secure_profile
    whitelist_enabled      = local.baseline_settings.minecraft.whitelist_enabled
    whitelist              = local.baseline_settings.minecraft.whitelist
    ops                    = local.baseline_settings.minecraft.ops
    rcon_password          = "smoke-test-rcon-secret"
    minecraft_image        = local.baseline_settings.containers.minecraft_server
    backup_image           = local.baseline_settings.containers.backup
    modrinth_modpack       = ""
    modrinth_projects      = local.baseline_settings.minecraft.modrinth_projects
    curseforge_projects    = []
    cf_api_key             = ""
    rcon_startup_commands  = ["say Smoke test startup RCON command verified"]
    plugins                = local.baseline_settings.minecraft.plugins
    backup_enabled         = local.baseline_settings.backup.enabled
    backup_interval        = local.baseline_settings.backup.interval
    backup_initial_delay   = local.baseline_settings.backup.initial_delay
    backup_retention_count = local.baseline_settings.backup.retention_count
    backup_s3_bucket       = "smoke-test-bucket"
    backup_s3_endpoint     = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider     = "Cloudflare"
    backup_s3_access_key   = "dummy-access-key"
    backup_s3_secret_key   = "dummy-secret-key"
  })

  docker_compose_modpack = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    server_type            = try(local.active_settings.minecraft.server_type, "MODRINTH")
    minecraft_version      = try(local.active_settings.minecraft.version, "1.21.1")
    jvm_memory             = try(local.active_settings.minecraft.jvm_memory, "6G")
    motd                   = local.active_settings.minecraft.motd
    max_players            = local.active_settings.minecraft.max_players
    difficulty             = local.active_settings.minecraft.difficulty
    online_mode            = local.active_settings.minecraft.online_mode
    enforce_secure_profile = local.active_settings.minecraft.enforce_secure_profile
    whitelist_enabled      = local.active_settings.minecraft.whitelist_enabled
    whitelist              = local.active_settings.minecraft.whitelist
    ops                    = local.active_settings.minecraft.ops
    rcon_password          = "smoke-test-rcon-secret"
    minecraft_image        = local.active_settings.containers.minecraft_server
    backup_image           = local.active_settings.containers.backup
    modrinth_modpack       = coalesce(try(trimspace(local.active_settings.minecraft.modrinth_modpack), ""), "create-combined")
    modrinth_projects      = try(local.active_settings.minecraft.modrinth_projects, ["mekanism", "ae2"])
    curseforge_projects    = length(try(local.active_settings.minecraft.curseforge_projects, [])) > 0 ? local.active_settings.minecraft.curseforge_projects : ["projecte"]
    cf_api_key             = "smoke-test-cf-$secret-key"
    rcon_startup_commands  = ["neologin setpassword Steve smoke-test-$auth-secret"]
    plugins                = try(local.active_settings.minecraft.plugins, [])
    backup_enabled         = local.active_settings.backup.enabled
    backup_interval        = local.active_settings.backup.interval
    backup_initial_delay   = local.active_settings.backup.initial_delay
    backup_retention_count = local.active_settings.backup.retention_count
    backup_s3_bucket       = "smoke-test-bucket"
    backup_s3_endpoint     = "https://example.r2.cloudflarestorage.com"
    backup_s3_provider     = "Cloudflare"
    backup_s3_access_key   = "dummy-access-key"
    backup_s3_secret_key   = "dummy-secret-key"
  })

  cloud_init = templatefile("${path.module}/../../iac/templates/cloud-init.yaml.tftpl", {
    always_on          = local.active_settings.server.always_on
    idle_timeout       = local.active_settings.server.idle_timeout_minutes
    github_repository  = "example-owner/example-repo"
    github_pat         = "smoke-test-github-pat"
    github_api_version = trimspace(file("${path.module}/../../.github-api-version"))
    keyboard_layout    = local.active_settings.server.keyboard_layout
    console_password   = "smoke-test-console-secret"
    volume_id          = "12345678"
    docker_compose     = local.docker_compose
    watchdog_script    = file("${path.module}/../../iac/files/scripts/idle-watchdog.sh")
    bootstrap_script   = file("${path.module}/../../iac/files/scripts/bootstrap-volume.sh")
    prune_script       = file("${path.module}/../../iac/files/scripts/prune-rclone-backups.sh")
    systemd_service    = file("${path.module}/../../iac/files/systemd/mc-idle-watchdog.service")
    systemd_timer      = file("${path.module}/../../iac/files/systemd/mc-idle-watchdog.timer")
  })
}

output "docker_compose" {
  value = local.docker_compose
}

output "docker_compose_modpack" {
  value = local.docker_compose_modpack
}

output "cloud_init" {
  value = local.cloud_init
}
