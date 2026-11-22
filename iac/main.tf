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
  rcon_password = coalesce(var.rcon_password, data.sops_file.secrets[0].data["rcon_password"])
  github_pat    = try(coalesce(var.github_pat, try(data.sops_file.secrets[0].data["github_pat"], null)), "")

  # Optional in-game authentication password/PIN (interpolated into rcon_startup_commands via ${AUTH_PASSWORD})
  raw_auth_password = try(coalesce(
    var.auth_password,
    try(data.sops_file.secrets[0].data["auth_password"], null),
    try(local.settings.minecraft.auth_password, null)
  ), "")
  auth_password = (
    trimspace(local.raw_auth_password) != "" &&
    lower(trimspace(local.raw_auth_password)) != "none"
  ) ? trimspace(local.raw_auth_password) : ""

  # Optional CurseForge API key for curseforge_projects
  raw_cf_api_key = try(coalesce(
    var.cf_api_key,
    try(data.sops_file.secrets[0].data["cf_api_key"], null)
  ), "")
  cf_api_key = trimspace(local.raw_cf_api_key)

  # Loader-agnostic modpack, project, plugin, and startup RCON command lists
  modrinth_modpack       = try(trimspace(local.settings.minecraft.modrinth_modpack), "")
  modrinth_exclude_files = try(local.settings.minecraft.modrinth_exclude_files, [])
  modrinth_projects      = try(local.settings.minecraft.modrinth_projects, [])
  curseforge_projects    = try(local.settings.minecraft.curseforge_projects, [])
  plugins                = try(local.settings.minecraft.plugins, [])

  raw_rcon_startup_commands = try(local.settings.minecraft.rcon_startup_commands, [])
  rcon_startup_commands = [
    for cmd in local.raw_rcon_startup_commands :
    replace(cmd, "$${AUTH_PASSWORD}", local.auth_password)
    if !can(regex("\\$\\{AUTH_PASSWORD\\}", cmd)) || local.auth_password != ""
  ]

  # Dedicated S3 / R2 Backup Configuration
  backup_s3_bucket     = try(data.sops_file.secrets[0].data["backup_s3_bucket"], "")
  backup_s3_endpoint   = try(data.sops_file.secrets[0].data["backup_s3_endpoint"], "")
  backup_s3_access_key = try(data.sops_file.secrets[0].data["backup_s3_access_key"], "")
  backup_s3_secret_key = try(data.sops_file.secrets[0].data["backup_s3_secret_key"], "")
  backup_s3_provider   = can(regex("r2\\.cloudflarestorage\\.com", local.backup_s3_endpoint)) ? "Cloudflare" : (can(regex("your-objectstorage\\.com|hetzner", local.backup_s3_endpoint)) ? "Ceph" : (can(regex("amazonaws\\.com", local.backup_s3_endpoint)) ? "AWS" : "Other"))

  # Explicit server settings & console credentials
  server_type      = coalesce(var.server_type, local.settings.server.server_type)
  ssh_keys         = local.settings.server.ssh_keys
  keyboard_layout  = local.settings.server.keyboard_layout
  console_password = data.sops_file.secrets[0].data["console_password"]

  # Optional Cloudflare Workers VPC Tunnel & mc-agent sidecar secrets
  cloudflare_tunnel_token = trimspace(try(coalesce(
    var.cloudflare_tunnel_token,
    try(data.sops_file.secrets[0].data["cloudflare_tunnel_token"], null)
  ), ""))
  agent_shared_secret = trimspace(try(coalesce(
    var.agent_shared_secret,
    try(data.sops_file.secrets[0].data["agent_shared_secret"], null)
  ), ""))
  discord_chat_webhook_url = trimspace(try(coalesce(
    var.discord_chat_webhook_url,
    try(data.sops_file.secrets[0].data["discord_chat_webhook_url"], null)
  ), ""))
  discord_command_webhook_url = trimspace(try(coalesce(
    var.discord_command_webhook_url,
    try(data.sops_file.secrets[0].data["discord_command_webhook_url"], null)
  ), ""))

  # DNS FQDN for boot readiness announcements
  dns_enabled = try(local.settings.dns.enabled, false)
  dns_domain  = try(local.settings.dns.domain, "")
  dns_subname = try(local.settings.dns.subname, "")
  server_fqdn = local.dns_enabled && local.dns_domain != "" ? (
    local.dns_subname != "" && local.dns_subname != "@"
    ? "${local.dns_subname}.${local.dns_domain}"
    : local.dns_domain
  ) : ""

  # Centralized container images
  minecraft_image   = local.settings.containers.minecraft_server
  backup_image      = local.settings.containers.backup
  mc_agent_image    = try(local.settings.containers.mc_agent, "ghcr.io/bumuellp/mc-agent:0.1.0")
  cloudflared_image = try(local.settings.containers.cloudflared, "cloudflare/cloudflared:2026.3.0")

  # Derive container cgroup mem_limit from jvm_memory with ~1680m headroom for JVM non-heap & native libs
  jvm_mem_norm = upper(trimspace(local.settings.minecraft.jvm_memory))
  jvm_mem_mb = endswith(local.jvm_mem_norm, "G") ? (
    tonumber(trimsuffix(local.jvm_mem_norm, "G")) * 1024
    ) : (
    endswith(local.jvm_mem_norm, "M") ? tonumber(trimsuffix(local.jvm_mem_norm, "M")) : 4096
  )
  mc_mem_limit = "${local.jvm_mem_mb + 1680}m"
}

data "hcloud_server_type" "server" {
  name = local.server_type
}

data "hcloud_images" "golden" {
  with_selector     = "role=minecraft-golden-image"
  with_architecture = [data.hcloud_server_type.server.architecture]
  most_recent       = true
}

locals {
  golden_image_id  = length(data.hcloud_images.golden.images) > 0 ? data.hcloud_images.golden.images[0].id : null
  use_golden_image = local.settings.server.use_golden_image && local.golden_image_id != null
  effective_image  = local.use_golden_image ? local.golden_image_id : "docker-ce"
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
    server_type                 = local.settings.minecraft.server_type
    minecraft_version           = local.settings.minecraft.version
    jvm_memory                  = local.settings.minecraft.jvm_memory
    mc_mem_limit                = local.mc_mem_limit
    motd                        = local.settings.minecraft.motd
    max_players                 = local.settings.minecraft.max_players
    difficulty                  = local.settings.minecraft.difficulty
    online_mode                 = local.settings.minecraft.online_mode
    enforce_secure_profile      = local.settings.minecraft.enforce_secure_profile
    whitelist_enabled           = local.settings.minecraft.whitelist_enabled
    whitelist                   = local.settings.minecraft.whitelist
    ops                         = local.settings.minecraft.ops
    rcon_password               = local.rcon_password
    minecraft_image             = local.minecraft_image
    backup_image                = local.backup_image
    mc_agent_image              = local.mc_agent_image
    cloudflared_image           = local.cloudflared_image
    cloudflare_tunnel_token     = local.cloudflare_tunnel_token
    agent_shared_secret         = local.agent_shared_secret
    discord_chat_webhook_url    = local.discord_chat_webhook_url
    discord_command_webhook_url = local.discord_command_webhook_url
    server_fqdn                 = local.server_fqdn
    server_location             = local.settings.server.location
    modrinth_modpack            = local.modrinth_modpack
    modrinth_exclude_files      = local.modrinth_exclude_files
    modrinth_projects           = local.modrinth_projects
    curseforge_projects         = local.curseforge_projects
    cf_api_key                  = local.cf_api_key
    rcon_startup_commands       = local.rcon_startup_commands
    plugins                     = local.plugins
    backup_enabled              = local.settings.backup.enabled
    backup_interval             = local.settings.backup.interval
    backup_initial_delay        = local.settings.backup.initial_delay
    backup_retention_count      = local.settings.backup.retention_count
    backup_s3_bucket            = local.backup_s3_bucket
    backup_s3_endpoint          = local.backup_s3_endpoint
    backup_s3_provider          = local.backup_s3_provider
    backup_s3_access_key        = local.backup_s3_access_key
    backup_s3_secret_key        = local.backup_s3_secret_key
  })

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    always_on              = (var.github_repository == null) ? false : local.settings.server.always_on
    idle_timeout           = local.settings.server.idle_timeout_minutes
    github_repository      = coalesce(var.github_repository, "")
    github_pat             = local.github_pat
    github_api_version     = trimspace(file("${path.module}/../.github-api-version"))
    keyboard_layout        = local.keyboard_layout
    console_password       = local.console_password
    volume_id              = module.volume.id
    docker_compose         = local.docker_compose
    modrinth_exclude_files = local.modrinth_exclude_files
    watchdog_script        = file("${path.module}/files/scripts/idle-watchdog.sh")
    bootstrap_script       = file("${path.module}/files/scripts/bootstrap-volume.sh")
    prune_script           = file("${path.module}/files/scripts/prune-rclone-backups.sh")
    systemd_service        = file("${path.module}/files/systemd/mc-idle-watchdog.service")
    systemd_timer          = file("${path.module}/files/systemd/mc-idle-watchdog.timer")
  })
}

# 4. Ephemeral Compute Instance
module "server" {
  source       = "git::https://github.com/bumuellp/tofu-bum.git//modules/hcloud-ephemeral-server?ref=v1.0.1"
  name         = var.server_name
  server_type  = local.server_type
  image        = local.effective_image
  location     = local.settings.server.location
  firewall_ids = [module.firewall.id]
  volume_id    = module.volume.id
  ssh_keys     = local.ssh_keys
  user_data    = local.cloud_init
}
