terraform {
  required_version = ">= 1.8.0"
}

locals {
  settings = yamldecode(file(fileexists("${path.module}/../../config/settings.yaml") ? "${path.module}/../../config/settings.yaml" : "${path.module}/../../config/settings.example.yaml"))
}

output "docker_compose" {
  value = templatefile("${path.module}/../../iac/templates/docker-compose.yml.tftpl", {
    minecraft_version = local.settings.minecraft.version
    jvm_memory        = "2G"
    motd              = local.settings.minecraft.motd
    max_players       = local.settings.minecraft.max_players
    difficulty        = local.settings.minecraft.difficulty
    rcon_password     = "smoke-test-rcon-secret"
    plugins           = local.settings.minecraft.plugins
    backup_enabled    = false
    backup_cron       = local.settings.backup.cron
  })
}
