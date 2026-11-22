# 🔧 Operations & Server Management

This guide covers routine operational workflows, automated idle shutdowns, off-site backups, machine image baking, and upstream template updates.

---

## 🚀 Starting and Stopping the Server

### Starting the Server

You can start the server via GitHub Actions or the Discord bot:

#### Option 1: GitHub Actions
1. Navigate to the **Actions** tab in your GitHub repository.
2. Select the **Start Minecraft Server** workflow.
3. Click **Run workflow** on the `main` branch.
4. The workflow runs automated pre-flight checks (`./scripts/preflight.sh`), provisions the Hetzner VM with the persistent volume attached, registers DNS records, and executes a TCP healthcheck on port `25565`.
5. Upon completion, the **Job Summary** displays:
   * Public IPv4 & IPv6 addresses
   * Fully Qualified Domain Name (FQDN)
   * Direct connection URLs for Java (`mc.example.com:25565`) and Bedrock (`mc.example.com:19132`)

#### Option 2: Discord Bot
If configured, run the slash command in your Discord server:
```text
/mc-start
```
The serverless bot verifies your ACL permissions, dispatches the workflow, and sends an embedded status card once the TCP port becomes reachable.

---

### Stopping the Server

#### Option 1: Automated Idle Watchdog
When zero players are connected to the server for `idle_timeout_minutes` (configured in `config/settings.yaml`), the on-server watchdog:
1. Detects `0` active players over consecutive RCON polls.
2. Broadcasts a countdown warning to in-game chat and flushes world chunks safely to the persistent block volume (`save-all flush`).
3. Dispatches the `server-stop.yml` GitHub Actions workflow via the scoped GitHub PAT (`github_pat` / `PAT_WATCHDOG`).

#### Option 2: Manual Teardown via GitHub Actions
1. Navigate to **Actions > Stop Minecraft Server**.
2. Click **Run workflow**.

#### Option 3: Discord Bot
Run the slash command:
```text
/mc-stop
```

### In-Game Management & Live Chat Bridge via Discord
When the optional `mc-agent` + `cloudflared` sidecars and Workers VPC are configured (see [Discord Bot Guide](../integrations/discord-bot/README.md)):
* **Automatic Boot Notification**: Once Minecraft passes RCON/startup checks, `mc-agent` posts a rich embed to `#mc-commands` (`discord_command_webhook_url`) with the active FQDN and direct IP.
* **Live Chat Bridge**: `mc-agent` tails `latest.log` (loader-agnostic across Vanilla, Fabric, NeoForge, and Paper) and forwards player chat, join, and leave messages to `#mc-chat` (`discord_chat_webhook_url`). Discord users can reply back into in-game chat via `/mc-say`.
* **RCON & Telemetry**: Run `/mc-players`, `/mc-top`, `/mc-logs`, `/mc-whitelist`, `/mc-backup`, `/mc-restart`, or `/mc-cmd` directly from Discord over the zero-trust Workers VPC tunnel.

#### 🛡️ Graceful ACPI Teardown
Both manual and automated stops issue an ACPI power signal to the Hetzner VM. Systemd intercepts the signal, sends SIGTERM to the Docker containers (allowing the Minecraft server to save chunks and cleanly disconnect players), unmounts the block volume, and shuts down cleanly before the VM is destroyed.

---

## 💾 Off-Site Cloud Backups (R2 / S3)

When `backup.enabled: true` is configured in `config/settings.yaml`:

```yaml
backup:
  enabled: true # Enable automated off-site cloud backups
  retention_count: 10 # Number of snapshots to retain
  interval: "1h" # Recurring snapshot interval while server is online
  initial_delay: "5m" # Delay after boot before taking first snapshot
```

An `mc-backup` sidecar container runs alongside the server in Docker Compose:
* **Periodic Snapshots**: Takes a compressed snapshot of the world data every `backup.interval` (e.g. `1h`).
* **S3 / Cloudflare R2 Upload**: Streams archives to your configured S3 bucket.
* **Automated Retention**: Keeps the latest `backup.retention_count` snapshots and prunes older archives both locally and remotely.

---

## 📦 Packer Golden Machine Images

When `server.use_golden_image: true` is configured in `config/settings.yaml`:

```yaml
server:
  use_golden_image: true # Boots from pre-baked Packer snapshot (~45s faster boot)
```

The server boots from a pre-cached Hetzner Cloud snapshot instead of downloading Docker containers and packages on every boot. This reduces cold boot time by **~45 seconds**.

### Baking a Golden Image
1. Navigate to **Actions > Build Golden Machine Image > Run workflow**.
2. A matrix of temporary ARM64 (`cax11`) and x86_64 (`cpx12`) builder VMs is booted in Hetzner Cloud (evaluating `packer.fallback_locations` automatically if a datacenter has temporary stock limits).
3. Packer installs Docker, pulls required architecture-native container images (`itzg/minecraft-server`, `itzg/mc-backup`, `cloudflare/cloudflared`, `ghcr.io/bumuellp/mc-agent`), pre-configures console keyboard layouts, and saves snapshots labeled `role=minecraft-golden-image` for both `arm` and `x86`.
4. **Automated Snapshot Rotation**: The workflow automatically rotates old snapshots per architecture, retaining only the latest ARM64 and x86_64 golden images so waterfall server placement (`cax21` $\rightarrow$ `cx33` $\rightarrow$ `cax31` $\rightarrow$ `cpx32`) always has a matching snapshot ready.

---

## 🔄 Switching Mod Loaders / Modpacks & Resetting or Resizing the Volume

Because `/mnt/mc-data` persists across server stops, switching between incompatible mod loaders or major Minecraft versions (for example, moving from a **Fabric 26.3 Crossplay** world to a **NeoForge 1.21.1 Modrinth/CurseForge modpack**) requires a clean volume or world directory so old mods and chunk data do not conflict.

### Recommended Clean Cutover Procedure
1. **Verify Off-Site Backup**:
   Before stopping the old server (or via `docker compose run --rm mc-backup`), confirm your latest world archive is present in your Cloudflare R2 / S3 backup bucket.
2. **Stop the Server**:
   Run `/mc-stop` in Discord (or run the **Stop Minecraft Server** workflow) so the ephemeral VM is destroyed and the volume is detached.
3. **Delete the Old Volume in Hetzner Cloud Console**:
   * Open the [Hetzner Cloud Console](https://console.hetzner.cloud/) $\rightarrow$ **Volumes**.
   * Delete the existing `<server-name>-data` volume.
   * *(Why this is safe with OpenTofu)*: During the next startup, `.github/scripts/provision-server.sh` always runs `tofu apply -target=module.volume -auto-approve` **before** planning the compute instance. OpenTofu refreshes state against the Hetzner API, detects that the old volume was deleted out-of-band, provisions a brand-new volume at your configured `server.volume_size_gb` (e.g. `15` GB for modded packs), and passes its new `volume_id` to the VM.
   * On first boot, `bootstrap-volume.sh` detects the unformatted block device, formats it with `mkfs.ext4 -L mc-data`, and mounts it at `/mnt/mc-data`.
4. **Update `config/settings.yaml` & Launch**:
   Commit your new `minecraft.*` loader/modpack settings (and any new `server.volume_size_gb`), push to `main`, and run `/mc-start`.

> [!TIP]
> **In-Place Volume Resizing (Without Deleting Data)**:
> If you only want to **increase** `server.volume_size_gb` (e.g. from `10` to `15` GB) while keeping your existing world, simply bump `volume_size_gb` in `config/settings.yaml` and push. Hetzner Cloud volumes support non-destructive online size increases via OpenTofu.

---

## 🧪 Container Smoke Testing

When modifying `iac/templates/docker-compose.yml.tftpl` or when Renovate creates pull requests updating container image tags:
* The `.github/workflows/container-smoke-test.yml` workflow renders the Docker Compose file, boots the container stack in a GitHub Actions runner, and confirms RCON responsiveness before merging.

---

## 🔄 Keeping Up to Date with Upstream Template

This repository inherits improvements and security updates from the upstream template [mine-your-own-bum](https://github.com/bumuellp/mine-your-own-bum).

### Automated Weekly Sync
The `.github/workflows/template-sync.yml` workflow runs weekly on Sundays at midnight UTC. If updates exist upstream, it automatically opens a pull request in your repository (`chore(template): sync updates from upstream`).

> [!IMPORTANT]
> **GitHub Secret `PAT_TEMPLATE_SYNC` Required**:
> Automated template synchronization creates Pull Requests that may modify GitHub Actions workflows (`.github/workflows/`). GitHub's default `GITHUB_TOKEN` is prevented from modifying workflows. You **must** configure a GitHub Fine-Grained Personal Access Token with `actions`, `contents`, `pull-requests`, and `workflows` permissions as a secret named `PAT_TEMPLATE_SYNC`, otherwise the workflow will fail with an authorization error. See [Template Sync PAT Setup](INFRASTRUCTURE_PROVIDERS.md#b-template-sync-pat-pat_template_sync-optional).

### Manual Sync
To synchronize upstream changes on-demand from your local machine:
```bash
./scripts/sync-template.sh
```
