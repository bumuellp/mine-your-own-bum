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
2. A temporary ARM Ampere `cax11` builder VM is booted in Hetzner Cloud.
3. Packer installs Docker, pulls required container images (`itzg/minecraft-server`, `itzg/mc-backup`), pre-configures console keyboard layouts, and saves a snapshot with label `role=minecraft-golden-image`.
4. **Automated Snapshot Rotation**: The workflow automatically rotates snapshots, retaining only the latest golden image so you do not incur excess snapshot storage fees.

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
