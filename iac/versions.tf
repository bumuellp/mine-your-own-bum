terraform {
  required_version = ">= 1.6.0"
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

  backend "s3" {
    # Instance parameters (bucket, endpoint, key) are injected at runtime via -backend-config
    key          = "mine-your-own-bum/terraform.tfstate"
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
