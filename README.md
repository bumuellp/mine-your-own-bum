# mine-your-own-bum

[![CI](https://github.com/bumuellp/mine-your-own-bum/actions/workflows/ci.yml/badge.svg)](https://github.com/bumuellp/mine-your-own-bum/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.13.1-FFDA44.svg)](https://opentofu.org/)

**Mine Your Own Bum** is a production-grade, public template repository for running **on-demand, cost-optimized Minecraft servers** on Hetzner Cloud.

It combines ephemeral compute instances with persistent block volume retention, automatic idle shutdown, dynamic DNS synchronization, and dual Java + Bedrock crossplay.

---

## 🌟 Key Architecture & Features

```
                              [ GitHub Actions ]
                                /             \
            (Workflow Dispatch / Schedule)   (Repository Dispatch from VM)
                              /                 \
                     [ server-start.yml ]     [ server-stop.yml ]
                             |                        |
                 [ OpenTofu / tofu-bum ]              |
                 - Attaches Block Volume              |
                 - Boots Cloud-Init Instance          |
                 - Updates Dynamic DNS                |
                             |                        |
                     (Server Running)                 |
                             |                        |
                   [ Idle Watchdog Timer ]            |
                   - Monitors RCON Players            |
                   - Saves World on 0 players         |
                   - Dispatches Teardown -------------+
```

- **Ephemeral Compute & Persistent Storage**: Compute instances are destroyed when not in use. World data, player states, and configs reside on an independent Hetzner block volume (`/mnt/mc-data`) that survives server shutdowns.
- **Auto-Stop Idle Watchdog**: A background systemd daemon checks player count via RCON. If zero players are active for a configurable idle timeout (default: 15 minutes), the server cleanly saves world data and dispatches a GitHub Action to destroy the VM.
- **Java & Bedrock Crossplay**: Powered by PaperMC with GeyserMC and Floodgate, allowing PC, mobile, and console players to play together seamlessly on standard ports (`25565` Java, `19132` Bedrock).
- **Dynamic DNS Integration**: Built-in support for **deSEC.io** and **IONOS Domain APIs** automatically publishes the server's public IPv4/IPv6 on start and removes it on shutdown.
- **Encrypted Secrets with SOPS + Age**: Keep API tokens safe directly inside your repository via GitOps encryption.

---

## 🛠️ Quick Start & Setup Guide

### 1. Use This Template
Click **"Use this template"** on GitHub to create your own private repository.

### 2. Configure Secrets with SOPS and Age

Generate a new Age keypair on your local machine:
```bash
age-keygen -o key.txt
```
Note the public key (`age1...`) and private key (`AGE-SECRET-KEY-1...`).

Update `.sops.yaml` with your public key:
```yaml
creation_rules:
  - path_regex: config/secrets\.enc\.yaml$
    age: "age1YOUR_PUBLIC_KEY..."
```

Create and encrypt your configuration:
```bash
cp config/secrets.example.yaml config/secrets.yaml
# Edit config/secrets.yaml with your tokens:
# - hcloud_token: Hetzner Cloud API token
# - rcon_password: Secure RCON password
# - github_pat: GitHub Personal Access Token (with repo dispatch permissions)
# - dns_token: deSEC API Token or IONOS API Key

sops --encrypt --in-place config/secrets.yaml
mv config/secrets.yaml config/secrets.enc.yaml
```

Commit `config/secrets.enc.yaml` to Git.

### 3. Configure GitHub Repository Secrets

Under your repository's **Settings > Secrets and variables > Actions**, add the single required private key:

| Secret | Required | Description |
| :--- | :---: | :--- |
| `SOPS_AGE_KEY` | **Yes** | Private Age key (`AGE-SECRET-KEY-1...`) used to decrypt `secrets.enc.yaml` |
| `PAT_TEMPLATE_SYNC` | *Optional* | GitHub PAT with `repo` and `workflow` scopes to allow automated template sync PRs to update `.github/workflows/` (defaults to `GITHUB_TOKEN`) |
| `PAT_WATCHDOG` | *Optional* | Fine-grained GitHub PAT with repository `actions: write` scope for the VM watchdog stop dispatcher (defaults to `github.token`) |

> [!TIP]
> **All provider tokens and remote state credentials live in SOPS!**
> Tokens like `hcloud_token`, `dns_token`, `rcon_password`, and S3 backend credentials (`s3_bucket`, `s3_endpoint`, `s3_access_key`, `s3_secret_key`) are stored directly in `config/secrets.enc.yaml` and decrypted automatically during workflow runs.

### 4. Customize Server Settings

Adjust `config/settings.yaml` (copy from `config/settings.example.yaml`):
```yaml
server:
  server_type: "cpx21"         # 3 vCPU AMD, 4 GB RAM (~€0.012/hour)
  location: "fsn1"             # Nuremberg, Germany (or falkenstein, helsinki)
  volume_size_gb: 10           # Persistent block volume
  always_on: false             # Set to true to disable auto-stop
  idle_timeout_minutes: 15     # Auto-stop after 15m of no players

minecraft:
  version: "LATEST"            # Target Minecraft Paper version
  jvm_memory: "6G"             # Java heap allocation
  motd: "Mine Your Own Bum"

dns:
  enabled: true
  provider: "desec"            # "desec" or "ionos"
  domain: "my-minecraft.dedyn.io"
  subname: "mc"
  ttl: 60
```

---

## 🚀 Starting and Stopping the Server

### Starting
1. Go to the **Actions** tab in GitHub.
2. Select **Start Minecraft Server**.
3. Click **Run workflow**.
4. Once completed, the **Job Summary** displays:
   - Server Public IPv4 / IPv6
   - Full DNS Domain (FQDN)
   - Connection URLs for Java (`mc.example.com:25565`) and Bedrock (`mc.example.com:19132`)

### Stopping
- **Automatic**: Stop occurs automatically when no players are connected for `idle_timeout_minutes`.
- **Manual**: Go to **Actions > Stop Minecraft Server > Run workflow**.

---

## 🔄 Keeping Up to Date with Upstream Template

This repository includes an automated weekly workflow (`.github/workflows/template-sync.yml`) that creates Pull Requests whenever improvements or security patches are merged into upstream `bumuellp/mine-your-own-bum`.

To manually trigger a sync at any time:
```bash
./scripts/sync-template.sh
```

---

## 📄 License

This repository is licensed under the [MIT License](LICENSE).
Reusable infrastructure modules are provided by [tofu-bum](https://github.com/bumuellp/tofu-bum).
CI/CD composite actions are powered by [lights-camera-bum-action](https://github.com/bumuellp/lights-camera-bum-action).
