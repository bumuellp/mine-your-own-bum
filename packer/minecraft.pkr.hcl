packer {
  required_plugins {
    hcloud = {
      version = ">= 1.4.0"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "server_type" {
  type        = string
  default     = "cax11"
  description = "Builder instance model (cax11 = 2 vCPU, 4GB RAM at €0.006/hr)"
}

variable "location" {
  type        = string
  default     = "fsn1"
  description = "Hetzner Cloud data center location"
}

variable "minecraft_image" {
  type        = string
  description = "Docker image tag for Minecraft server (from settings.yaml)"
}

variable "backup_image" {
  type        = string
  description = "Docker image tag for Minecraft backup (from settings.yaml)"
}

variable "keyboard_layout" {
  type        = string
  default     = "de"
  description = "Virtual console keyboard layout (from settings.yaml)"
}

source "hcloud" "golden_image" {
  token        = var.hcloud_token
  image        = "docker-ce"
  server_type  = var.server_type
  location     = var.location
  ssh_username = "root"

  snapshot_name = "minecraft-golden-image-{{timestamp}}"
  snapshot_labels = {
    role       = "minecraft-golden-image"
    managed_by = "packer"
    created_at = "{{timestamp}}"
  }
}

build {
  sources = ["source.hcloud.golden_image"]

  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for initial cloud-init...'; sleep 2; done",
      "systemctl start docker",
      "echo '==> Pre-caching Docker container images...'",
      "docker pull ${var.minecraft_image}",
      "docker pull ${var.backup_image}",
      "echo '==> Pre-configuring keyboard layout...'",
      "localectl set-keymap ${var.keyboard_layout} || loadkeys ${var.keyboard_layout} || true",
      "echo '==> Sanitizing instance state...'",
      "docker image prune -f",
      "cloud-init clean --logs --seed",
      "rm -rf /tmp/* /var/tmp/*",
      "sync"
    ]
  }
}
