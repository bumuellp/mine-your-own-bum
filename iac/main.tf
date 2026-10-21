locals {
  settings_file = fileexists("${path.module}/../config/settings.yaml") ? "${path.module}/../config/settings.yaml" : "${path.module}/../config/settings.example.yaml"
  settings      = yamldecode(file(local.settings_file))
}

data "sops_file" "secrets" {
  count       = fileexists("${path.module}/../config/secrets.enc.yaml") ? 1 : 0
  source_file = "${path.module}/../config/secrets.enc.yaml"
}

locals {
  hcloud_token  = coalesce(var.hcloud_token, try(data.sops_file.secrets[0].data["hcloud_token"], null))
  rcon_password = coalesce(var.rcon_password, try(data.sops_file.secrets[0].data["rcon_password"], "secret-mc-rcon-pass"))
  github_pat    = try(coalesce(var.github_pat, try(data.sops_file.secrets[0].data["github_pat"], null)), "")

  # Dedicated S3 / R2 Backup Configuration
  backup_s3_bucket     = try(data.sops_file.secrets[0].data["backup_s3_bucket"], "")
  backup_s3_endpoint   = try(data.sops_file.secrets[0].data["backup_s3_endpoint"], "")
  backup_s3_access_key = try(data.sops_file.secrets[0].data["backup_s3_access_key"], "")
  backup_s3_secret_key = try(data.sops_file.secrets[0].data["backup_s3_secret_key"], "")
  backup_s3_provider   = can(regex("r2\\.cloudflarestorage\\.com", local.backup_s3_endpoint)) ? "Cloudflare" : (can(regex("your-objectstorage\\.com|hetzner", local.backup_s3_endpoint)) ? "Ceph" : (can(regex("amazonaws\\.com", local.backup_s3_endpoint)) ? "AWS" : "Other"))
}

provider "hcloud" {
  token = local.hcloud_token
}

# 1. Persistent Storage (Retained across server destructions)
module "volume" {
  source   = "git::https://github.com/bumuellp/tofu-bum.git//modules/hcloud-volume?ref=v1.0.1"
  name     = "${var.server_name}-data"
  size     = local.settings.server.volume_size_gb
  location = local.settings.server.location
}

# 2. Network Firewall (Minecraft Java + Bedrock + optional SSH)
locals {
  minecraft_rules = [
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "25565"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "Minecraft Java Edition"
    },
    {
      direction   = "in"
      protocol    = "udp"
      port        = "19132"
      source_ips  = ["0.0.0.0/0", "::/0"]
      description = "Minecraft Bedrock Edition (Geyser)"
    }
  ]

  ssh_rules = length(local.settings.server.ssh_allowed_ips) > 0 ? [
    {
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = local.settings.server.ssh_allowed_ips
      description = "SSH Access"
    }
  ] : []

  firewall_rules = concat(local.minecraft_rules, local.ssh_rules)
}

module "firewall" {
  source = "git::https://github.com/bumuellp/tofu-bum.git//modules/hcloud-firewall?ref=v1.0.1"
  name   = "${var.server_name}-firewall"
  rules  = local.firewall_rules
}

# 3. Cloud-Init Manifest & Compose Orchestration
locals {
  docker_compose = templatefile("${path.module}/templates/docker-compose.yml.tftpl", {
    minecraft_version      = local.settings.minecraft.version
    jvm_memory             = local.settings.minecraft.jvm_memory
    motd                   = local.settings.minecraft.motd
    max_players            = local.settings.minecraft.max_players
    difficulty             = local.settings.minecraft.difficulty
    whitelist_enabled      = local.settings.minecraft.whitelist_enabled
    whitelist              = local.settings.minecraft.whitelist
    ops                    = local.settings.minecraft.ops
    rcon_password          = local.rcon_password
    plugins                = local.settings.minecraft.plugins
    backup_enabled         = local.settings.backup.enabled
    backup_interval        = local.settings.backup.interval
    backup_initial_delay   = local.settings.backup.initial_delay
    backup_retention_count = local.settings.backup.retention_count
    backup_s3_bucket       = local.backup_s3_bucket
    backup_s3_endpoint     = local.backup_s3_endpoint
    backup_s3_provider     = local.backup_s3_provider
    backup_s3_access_key   = local.backup_s3_access_key
    backup_s3_secret_key   = local.backup_s3_secret_key
  })

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    always_on         = local.settings.server.always_on
    idle_timeout      = local.settings.server.idle_timeout_minutes
    github_repository = var.github_repository
    github_pat        = local.github_pat
    volume_id         = module.volume.id
    docker_compose    = local.docker_compose
    watchdog_script   = file("${path.module}/files/scripts/idle-watchdog.sh")
    bootstrap_script  = file("${path.module}/files/scripts/bootstrap-volume.sh")
    systemd_service   = file("${path.module}/files/systemd/mc-idle-watchdog.service")
    systemd_timer     = file("${path.module}/files/systemd/mc-idle-watchdog.timer")
  })
}

# 4. Ephemeral Compute Instance
module "server" {
  source       = "git::https://github.com/bumuellp/tofu-bum.git//modules/hcloud-ephemeral-server?ref=v1.0.1"
  name         = var.server_name
  server_type  = local.settings.server.server_type
  image        = "docker-ce"
  location     = local.settings.server.location
  firewall_ids = [module.firewall.id]
  volume_id    = module.volume.id
  user_data    = local.cloud_init
}
