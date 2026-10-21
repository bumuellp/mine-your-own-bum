terraform {
  required_version = ">= 1.7.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = ">= 1.0.0"
    }
  }

  encryption {
    key_provider "pbkdf2" "state_key" {
      passphrase = var.state_encryption_passphrase
    }

    method "aes_gcm" "state_cipher" {
      keys = key_provider.pbkdf2.state_key
    }

    state {
      method   = method.aes_gcm.state_cipher
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state_cipher
      enforced = true
    }
  }

  backend "s3" {
    # Instance parameters (bucket, endpoint, key) are injected at runtime via -backend-config
    key          = "mine-your-own-bum/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # Non-AWS S3-compatible storage bypasses (Hetzner Object Storage / MinIO / Ceph)
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
