# mine-your-own-bum

[![CI](https://github.com/bumuellp/mine-your-own-bum/actions/workflows/ci.yml/badge.svg)](https://github.com/bumuellp/mine-your-own-bum/actions/workflows/ci.yml)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-1.13.1-FFDA44.svg?logo=opentofu&logoColor=black)](https://opentofu.org/)
[![Rust](https://img.shields.io/badge/Rust-2024-DEA584.svg?logo=rust&logoColor=black)](https://www.rust-lang.org/)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Mine Your Own Bum** is a public template repository for running **on-demand, cost-optimized Minecraft servers** on Hetzner Cloud.

It combines ephemeral compute instances with persistent block volume retention, automatic idle shutdown, dynamic DNS synchronization, dual Java + Bedrock crossplay, and optional Discord bot integration, off-site cloud backups, and pre-baked snapshot machine images.

---

## 🌟 Key Architecture & Highlights

```mermaid
flowchart TB
    subgraph Discord["💬 Discord Server (#mc-commands & #mc-chat)"]
        User["Discord User"]
        WHCmd["#mc-commands Webhook<br>(Boot Ready Embed)"]
        WHChat["#mc-chat Webhook<br>(Live Chat, Joins & Leaves)"]
    end

    subgraph CF["☁️ Cloudflare Edge (100% Free Tier)"]
        Worker["Discord Bot Worker (Rust / WASM)<br>Ed25519 Verify • Channel & Tiered ACL"]
        VPC["Cloudflare Workers VPC<br>([[vpc_services]] MC_AGENT Binding)"]
    end

    subgraph GHA["⚙️ GitHub Actions & OpenTofu State"]
        Start["server-start.yml<br>• resolve-hcloud-placement (cax21→cx33→cax31→cpx32)<br>• preflight.sh & OpenTofu Apply<br>• Dynamic DNS Sync (deSEC / IONOS / Hetzner)"]
        Stop["server-stop.yml<br>• DNS Cleanup & Graceful ACPI Shutdown<br>• tofu destroy -target=module.server"]
        S3State[("Cloudflare R2 / S3<br>AES-GCM Encrypted State<br>& World Backups")]
        CI["Independent CI/CD Pipelines<br>• packer-build.yml (ARM64 cax11 + x86_64 cpx12 Golden Images)<br>• build-mc-agent.yml (Multi-Arch Rust → GHCR)<br>• deploy-discord-bot.yml (Worker Deploy & 11 Command Sync)<br>• container-smoke-test.yml (Compose + RCON E2E)"]
    end

    subgraph Hetzner["🖥️ Hetzner Cloud Ephemeral VM + Persistent Volume (/mnt/mc-data)"]
        direction TB
        CFd["cloudflared Sidecar<br>(Outbound TLS 1.3 / QUIC Tunnel)"]
        Agent["mc-agent Sidecar (Rust :8080)<br>• Bearer Auth & RCON Client<br>• /proc & statvfs Telemetry<br>• latest.log Tailer & IP Redactor"]
        MC["mc-server (itzg/minecraft-server)<br>Java :25565 • Bedrock UDP :19132 • RCON :25575<br>Vanilla / Fabric / NeoForge / Modrinth / CurseForge"]
        Backup["mc-backup Sidecar<br>(Periodic Rclone Snapshots & Pruning)"]
        Watchdog["systemd mc-idle-watchdog<br>(0-Player RCON Poll → save-all flush)"]
    end

    User -->|"/mc-start, /mc-stop, /mc-status"| Worker
    User -->|"/mc-players, /mc-top, /mc-logs, /mc-say,<br>/mc-whitelist, /mc-backup, /mc-restart, /mc-cmd"| Worker

    Worker -->|"Lifecycle Dispatch & Mutex Check"| Start
    Worker -->|"Lifecycle Dispatch"| Stop
    Worker -.->|"Direct TCP :25565 SLP Ping"| MC
    Worker ==>|"env.service('MC_AGENT')"| VPC

    Start <-->|"PBKDF2 + AES-GCM"| S3State
    Stop <-->|"PBKDF2 + AES-GCM"| S3State
    Start ==>|"Reconcile Volume, Boot Golden Image<br>(ARM64 or x86_64) & Attach /mnt/mc-data"| Hetzner
    Stop ==>|"ACPI Poweroff & Destroy Compute Only"| Hetzner

    CFd <==>|"Outbound-Only Encrypted Tunnel<br>(Zero Inbound Admin Ports)"| VPC
    CFd -->|"Local Docker Bridge<br>http://mc-agent:8080"| Agent
    Agent <-->|"RCON :25575 & ro /logs + /proc"| MC
    Agent -->|"Boot Ready Embed"| WHCmd
    Agent -->|"Live Chat / Join / Leave"| WHChat
    Backup -->|"Upload & Prune Archives"| S3State
    Watchdog -->|"Idle Timeout Reached"| Stop
```

* **Pay-Per-Play Model (~€0.45–€0.68/month idle)**: Compute instances are destroyed when not in use. You only pay for the idle persistent block volume (`10–15 GB`); compute costs drop to **€0.00/h** when stopped.
* **Multi-Arch Waterfall Placement & Golden Images**: Preflight automatically probes live Hetzner datacenter stock across your primary and fallback models (`cax21` $\rightarrow$ `cx33` $\rightarrow$ `cax31` $\rightarrow$ `cpx32`) and selects the matching pre-baked **ARM64 or x86_64 Packer golden snapshot** (with automatic fallback to `docker-ce`).
* **Auto-Stop Idle Watchdog**: An on-server systemd daemon detects 0 active players, cleanly saves world chunks via RCON, and triggers automated teardown.
* **Zero-Loss Graceful ACPI Teardown**: Intercepts ACPI power signals, allowing systemd and Docker to trap SIGTERM, cleanly flush world chunks, and unmount block storage safely before VM destruction.
* **Declarative Loader & Modpack Support**: Switch cleanly between Vanilla/Fabric (e.g. Geyser + Floodgate Java/Bedrock crossplay) and modded stacks (e.g. NeoForge, Modrinth modpacks, CurseForge mods) purely via `config/settings.yaml`.
* **Zero-Trust Sidecar & Live Chat Bridge**: `mc-agent` + `cloudflared` connect via **Cloudflare Workers VPC** (free tier, no custom domain needed) for live Discord chat bridging, boot ready embeds, RCON commands, host telemetry, and redacted log tailing without opening extra firewall ports.
* **GitOps Secrets with Age + SOPS**: Store encrypted provider tokens and credentials directly in your Git repository.
* **Client-Side State Encryption**: End-to-end client-side encryption of OpenTofu state files on the S3 backend using **PBKDF2** and **AES-GCM** (`aes_gcm`).
* **Serverless Discord Bot**: Optional 11-command slash bot written in pure Rust compiled to WebAssembly on Cloudflare Workers (100% free tier).

---

## 📚 Documentation Index (The Roadmap)

Follow this structured journey to set up, operate, and customize your server:

| Step | Guide | Description |
|:---:|---|---|
| **1** | [☁️ **Infrastructure & Providers**](docs/INFRASTRUCTURE_PROVIDERS.md) | Where to click and what credentials to create across Hetzner, Cloudflare R2/S3, and GitHub. |
| **2** | [🚀 **Setup & Installation**](docs/SETUP.md) | Onboarding guide: Age key generation, SOPS secrets encryption, and GitHub repository secrets. |
| **3** | [⚙️ **Configuration Reference**](docs/CONFIGURATION.md) | Exhaustive parameter schema for `config/settings.yaml` and Renovate dependency setup. |
| **4** | [🛡️ **Player Management & Whitelist**](docs/PLAYER_MANAGEMENT.md) | Crossplay access control, `/whitelist` vs `/fwhitelist`, Bedrock UUID resolution, and operators. |
| **5** | [🎮 **Connecting to the Server**](docs/CONNECTING.md) | Client connection instructions for Java, Bedrock (Mobile/PC), and Consoles (BedrockTogether). |
| **6** | [🔧 **Operations & Management**](docs/OPERATIONS.md) | Server lifecycle, automated idle watchdog, R2 off-site backups, and Packer golden images. |
| **7** | [🤖 **Discord Bot Guide**](integrations/discord-bot/README.md) | Optional serverless slash-command bot (11 commands, RCON/telemetry via Workers VPC, live chat bridge) on Cloudflare Workers. |
| **8** | [🩺 **Troubleshooting & FAQ**](docs/TROUBLESHOOTING.md) | Unlocking OpenTofu locks, DNS negative caching on rapid restarts, offline-mode players, and fixes. |

---

## ⚡ 5-Minute Quickstart

1. **Provider Accounts**:
   Obtain your Hetzner Cloud token, Cloudflare R2 / S3 credentials, and GitHub PAT as outlined in the [Infrastructure Providers Guide](docs/INFRASTRUCTURE_PROVIDERS.md).
2. **Use This Template**:
   Click **"Use this template"** on GitHub to create your private repository, then clone it locally.
3. **Configure Secrets**:
   Set up your Age key and initialize encrypted secrets:
   ```bash
   mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt
   # Add your public key to .sops.yaml, then initialize secrets:
   cp config/secrets.example.yaml config/secrets.enc.yaml
   sops --encrypt --in-place config/secrets.enc.yaml
   sops config/secrets.enc.yaml  # Add your Hetzner, S3, and GitHub PAT credentials
   ```
4. **Add GitHub Secret**:
   Add `SOPS_AGE_KEY` (the private key from `~/.config/sops/age/keys.txt`) under **Settings > Secrets and variables > Actions**.
5. **Deploy**:
   Commit and push your `config/settings.yaml`. Go to **Actions > Start Minecraft Server > Run workflow**.

For complete step-by-step onboarding details, see the [Setup & Installation Guide](docs/SETUP.md).

---

## 🎮 Quick Connection Info

| Platform | Default Port | Notes |
|---|:---:|---|
| **Java Edition** (PC, Mac, Linux) | `25565` (TCP) | Connect via your domain (e.g. `mc.example.com`) or server IP. |
| **Bedrock Edition** (Mobile, Windows) | `19132` (UDP) | Connect via your domain or server IP on port `19132`. |
| **Consoles** (Xbox, PlayStation, Switch) | `19132` (UDP) | Use the free **BedrockTogether** app on your phone. See [Connecting Guide](docs/CONNECTING.md). |

---

## 📄 License

This repository is licensed under the [MIT License](LICENSE).
Reusable infrastructure modules provided by [tofu-bum](https://github.com/bumuellp/tofu-bum).
CI/CD composite actions powered by [lights-camera-bum-action](https://github.com/bumuellp/lights-camera-bum-action).
