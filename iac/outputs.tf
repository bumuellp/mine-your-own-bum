output "server_id" {
  description = "ID of the ephemeral Minecraft compute instance in Hetzner Cloud"
  value       = module.server.id
}

output "server_ipv4" {
  description = "Public IPv4 address of the ephemeral Minecraft server"
  value       = module.server.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the ephemeral Minecraft server"
  value       = module.server.ipv6_address
}

output "volume_id" {
  description = "ID of the persistent volume retaining world data"
  value       = module.volume.id
}

output "firewall_id" {
  description = "ID of the active firewall protecting the server"
  value       = module.firewall.id
}

output "connection_java" {
  description = "Connection address for Minecraft Java Edition"
  value       = "${module.server.ipv4_address}:25565"
}

output "connection_bedrock" {
  description = "Connection address for Minecraft Bedrock Edition (Geyser)"
  value       = "${module.server.ipv4_address}:19132"
}

output "dns_enabled" {
  description = "Whether dynamic DNS synchronization is enabled"
  value       = try(local.settings.dns.enabled, false)
}

output "dns_provider" {
  description = "Configured DNS provider (desec, ionos, or hetzner)"
  value       = try(local.settings.dns.provider, "desec")
}

output "dns_domain" {
  description = "Configured apex or root DNS domain"
  value       = try(local.settings.dns.domain, "")
}

output "dns_subname" {
  description = "Configured subdomain prefix"
  value       = try(local.settings.dns.subname, "")
}

output "dns_ttl" {
  description = "Configured DNS TTL in seconds"
  value       = try(local.settings.dns.ttl, 60)
}

output "dns_fqdn" {
  description = "Full Qualified Domain Name computed from subname and domain"
  value = try(
    local.settings.dns.subname != "" && local.settings.dns.subname != "@" ?
    "${local.settings.dns.subname}.${local.settings.dns.domain}" :
    local.settings.dns.domain,
    ""
  )
}

output "dns_token" {
  description = "Authentication token for DNS provider (from SOPS secrets)"
  value       = try(data.sops_file.secrets[0].data["dns_token"], "")
  sensitive   = true
}
