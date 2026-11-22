# ⚙️ Configuration Reference

All operational, game, and infrastructure behaviors are configured via `config/settings.yaml`.

> [!NOTE]
> During onboarding in the [Setup Guide](SETUP.md), `config/settings.yaml` was initialized by copying `config/settings.example.yaml`. Any changes you commit and push to `config/settings.yaml` are automatically picked up by GitHub Actions on the next server launch.

---

## 📄 Annotated Example Configuration

```yaml
---
server:
  server_type: "cax21" # 4 vCPU ARM Ampere, 8 GB RAM (~€0.017/hour)
  fallback_server_types: # Waterfall fallback if primary type is unavailable in location
    - "cx33"
    - "cax31"
    - "cpx32"
  location: "fsn1" # Falkenstein, Germany (or nbg1, hel1)
  volume_size_gb: 10 # Persistent Hetzner block volume (min 10 GB)
  always_on: false # When true, disables the idle auto-stop watchdog
  idle_timeout_minutes: 15 # Minutes of 0 players before automated teardown
  keyboard_layout: "de" # Console keyboard layout ("de", "us", etc.)
  use_golden_image: true # Pre-baked Packer snapshot (saves ~45s boot, recommended)
  ssh_keys: # Hetzner SSH key names (suppresses password emails)
    - "your-ssh-key-name"
  ssh_allowed_ips: [] # Whitelist CIDRs for SSH or [] to drop TCP 22

minecraft:
  server_type: "FABRIC" # "FABRIC", "PAPER", "NEOFORGE", "MODRINTH", etc.
  version: "26.3" # renovate: datasource=mojang-java
  jvm_memory: "5G" # Java heap allocation (-Xmx)
  motd: "Mine Your Own Bum" # Message of the day in server list
  max_players: 20 # Maximum simultaneous players
  difficulty: "normal" # peaceful, easy, normal, hard
  online_mode: true # Mojang session authentication (false for LAN/offline)
  enforce_secure_profile: true # Require signed player chat profiles
  whitelist_enabled: true # Enforce player access control
  whitelist:
    - "Steve" # Java username or Bedrock Floodgate UUID
  ops:
    - "Steve" # Server operator (permission level 4)
  modrinth_modpack: "" # Optional Modrinth modpack slug (e.g. "create-combined")
  modrinth_projects: # Dynamic mods loaded from Modrinth
    - "fabric-api"
    - "lithium"
    - "ferrite-core"
    - "krypton"
    - "carpet"
    - "geyser:beta" # Geyser continuous beta channel build
    - "floodgate:beta" # Floodgate continuous beta channel build
  curseforge_projects: [] # Optional CurseForge project slugs/IDs (requires cf_api_key in SOPS)
  rcon_startup_commands: [] # Optional startup RCON commands (supports ${AUTH_PASSWORD})
  plugins: [] # Direct jar download URLs (for Paper/Bukkit plugins)

dns:
  enabled: false # Set true once DNS provider credentials are configured
  provider: "desec" # Supported: "desec", "ionos", or "hetzner"
  domain: "example.com" # Registered apex / zone domain
  subname: "mc" # Subdomain prefix (e.g. mc.example.com)
  ttl: 60 # Record TTL in seconds

backup:
  enabled: false # Automated off-site R2/S3 cloud backups
  retention_count: 10 # Number of snapshots to retain
  interval: "1h" # Recurring snapshot interval while online
  initial_delay: "5m" # Delay after boot before taking first snapshot

containers:
  minecraft_server: "itzg/minecraft-server:2026.10.0" # renovate: datasource=docker depName=itzg/minecraft-server
  backup: "itzg/mc-backup:2026.10.1" # renovate: datasource=docker depName=itzg/mc-backup
  cloudflared: "cloudflare/cloudflared:2026.3.0" # renovate: datasource=docker depName=cloudflare/cloudflared
  mc_agent: "ghcr.io/bumuellp/mc-agent:0.1.0" # renovate: datasource=docker depName=ghcr.io/bumuellp/mc-agent

packer:
  arm_builder: "cax11" # Model used to build ARM golden image snapshot
  x86_builder: "cpx12" # Model used to build x86 golden image snapshot (min 40GB disk)
  fallback_locations: # Builder datacenter fallback order (snapshots are global)
    - "fsn1"
    - "nbg1"
    - "hel1"

discord:
  enabled: false # Deploy serverless Discord bot on Cloudflare Workers
  command_channel_id: "" # Optional: restrict operational commands to #mc-commands
  chat_channel_id: "" # Optional: restrict /mc-say to #mc-chat
  allowed_user_ids: [] # Restrict lifecycle & admin commands to specific Discord IDs
```

---

## 📋 Parameter Reference

### `server`

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `server_type` | `string` | `"cax21"` | Hetzner Cloud VM model (e.g. `cax21`, `cx33`, `cax31`, `cpx32`). `cax21` (4 vCPU ARM Ampere, 8 GB RAM) is recommended for smooth chunk generation and cost efficiency. |
| `fallback_server_types` | `list` | `["cx33", "cax31", "cpx32"]` | Ordered list of fallback machine models tested in preflight if `server_type` is unavailable in the datacenter location. |
| `location` | `string` | `"fsn1"` | Hetzner datacenter location (`fsn1` = Falkenstein, `nbg1` = Nuremberg, `hel1` = Helsinki). *Note: Persistent volumes are currently available in EU regions.* |
| `volume_size_gb` | `number` | `10` | Size of the persistent Hetzner block volume retaining Minecraft world data across shutdowns (minimum 10 GB). |
| `always_on` | `bool` | `false` | When `true`, disables the auto-stop watchdog; the VM stays running until stopped manually via workflow. |
| `idle_timeout_minutes` | `number` | `15` | Minutes with 0 active players before saving the world and triggering automated VM teardown. |
| `keyboard_layout` | `string` | `"de"` | Virtual console keyboard layout (`"de"`, `"us"`, `"uk"`, etc.) loaded automatically on boot. |
| `use_golden_image` | `bool` | `true` | When `true`, provisions the server using a pre-baked Hetzner snapshot image created by Packer (containing pre-cached Docker images and keyboard layout), reducing cold startup time by ~45 seconds. Setting to `true` is **strongly recommended**. |
| `ssh_keys` | `list` | `[...]` | List of SSH key names/IDs in your Hetzner Cloud project. Attaching at least one key suppresses root password emails from Hetzner. |
| `ssh_allowed_ips` | `list` | `[]` | Whitelist of IPv4/IPv6 CIDR ranges allowed to connect via SSH port 22 (e.g. `["203.0.113.50/32"]`). Leave empty `[]` to drop all port 22 traffic. |

---

### `minecraft`

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `server_type` | `string` | `"FABRIC"` | Minecraft server implementation (`"FABRIC"`, `"PAPER"`, `"NEOFORGE"`, `"MODRINTH"`, etc.). |
| `version` | `string` | `"26.3"` | Target Minecraft version (e.g. `"26.3"`, `"1.21.1"`, `"LATEST"`). Tracked automatically by Renovate via `# renovate: datasource=mojang-java`. |
| `jvm_memory` | `string` | `"5G"` | Java heap memory allocation (`-Xmx`). Aikar's GC flags are applied automatically for optimal pause times. |
| `motd` | `string` | `"..."` | Message of the day displayed in the multiplayer server list. |
| `max_players` | `number` | `20` | Maximum simultaneous players allowed. |
| `difficulty` | `string` | `"normal"` | In-game difficulty (`peaceful`, `easy`, `normal`, `hard`). |
| `online_mode` | `bool` | `true` | When `true`, authenticates connecting players against Mojang session servers. Set to `false` for offline or LAN-only play. |
| `enforce_secure_profile` | `bool` | `true` | When `true`, requires players to have a Mojang-signed public key / secure chat profile. Set `false` if using offline mode or clients without signed profiles. |
| `whitelist_enabled` | `bool` | `true` | When `true`, enforces native player access control. Unauthorized players cannot connect. See [Player Management Guide](PLAYER_MANAGEMENT.md). |
| `whitelist` | `list` | `[...]` | Whitelisted players. Java players use username (e.g. `"Steve"`). Bedrock players use Floodgate UUIDs (e.g. `"00000000-0000-0000-xxxx-xxxxxxxxxxxx"` derived from Xbox XUID). |
| `ops` | `list` | `[...]` | Server operators granted permission level 4 (`/gamemode`, `/fwhitelist`, `/kick`, etc.). Format matches `whitelist`. |
| `modrinth_modpack` | `string` | `""` | Optional Modrinth modpack slug, channel, or version (e.g. `"create-combined:beta"`, `"cobblemon-fabric"`, or `"create-combined:2.0.0B8"`). Supports `:release`, `:beta`, `:alpha`, or `:version` suffixes. Automatically increases the container startup healthcheck `start_period` to `5m`. |
| `modrinth_projects` | `list` | `[...]` | Mods/plugins resolved and downloaded from Modrinth automatically on boot (loader-specific). Individual release channels or versions can be specified using `slug:channel` (e.g. `geyser:beta`, `floodgate:beta`) or pinned versions (`slug:version`). Unqualified mods default to stable `release`. |
| `curseforge_projects` | `list` | `[]` | Optional CurseForge project slugs or numeric IDs downloaded automatically on boot. Requires `cf_api_key` in `config/secrets.enc.yaml`. |
| `rcon_startup_commands` | `list` | `[]` | Optional RCON commands executed automatically once the server finishes booting (e.g. configuring offline-mode auth mods). Supports `${AUTH_PASSWORD}` placeholder interpolation from SOPS `auth_password`. |
| `plugins` | `list` | `[]` | HTTP/HTTPS direct download URLs for jar plugins (primarily for Paper/Bukkit servers or standalone jars). |

---

### `dns`

> [!TIP]
> For instructions on obtaining your API key from deSEC, IONOS, or Hetzner, see the [DNS Provider Setup Guide](INFRASTRUCTURE_PROVIDERS.md#4-dynamic-dns-provider-optional).

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `enabled` | `bool` | `false` | Enable automated public DNS registration on boot and cleanup on shutdown. |
| `provider` | `string` | `"desec"` | DNS provider API (`"desec"`, `"ionos"`, or `"hetzner"`). |
| `domain` | `string` | `"..."` | Your registered **apex / zone domain** in your DNS provider (e.g. `"example.com"` or `"my-server.dedyn.io"`). |
| `subname` | `string` | `"mc"` | Subdomain prefix (e.g. `"mc"` or `"mine-your-own-bum"`). Use `""` or `"@"` for apex root domain. |
| `ttl` | `number` | `60` | DNS record TTL in seconds (low value like `60` recommended for ephemeral dynamic IPs). |

---

### `backup`

> [!TIP]
> For details on snapshot intervals, R2/S3 storage policies, and world restores, see [Off-Site Cloud Backups in Operations](OPERATIONS.md#off-site-cloud-backups-r2--s3).

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `enabled` | `bool` | `false` | Enable automated off-site cloud backups to Cloudflare R2 / S3 via `mc-backup` sidecar. |
| `retention_count` | `number` | `10` | Number of recent backups to keep. Automatically prunes older backups both locally and in remote R2 storage. |
| `interval` | `string` | `"1h"` | Interval between recurring snapshots while the server is actively running. |
| `initial_delay` | `string` | `"5m"` | Delay after boot before taking the first baseline snapshot. |

---

### `containers`

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `minecraft_server` | `string` | `"itzg/minecraft-server:2026.10.0"` | Docker image tag for the Minecraft server container. Tracked and updated automatically by Renovate. |
| `backup` | `string` | `"itzg/mc-backup:2026.10.1"` | Docker image tag for the Rclone backup sidecar container. Tracked and updated automatically by Renovate. |
| `cloudflared` | `string` | `"cloudflare/cloudflared:2026.3.0"` | Docker image tag for the outbound Cloudflare Tunnel sidecar (activated when `cloudflare_tunnel_token` is set in SOPS). Tracked by Renovate. |
| `mc_agent` | `string` | `"ghcr.io/bumuellp/mc-agent:0.1.0"` | Docker image tag for the Rust RCON/telemetry/chat-bridge sidecar agent (activated alongside `cloudflared`). Tracked by Renovate. |

---

### `packer`

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `arm_builder` | `string` | `"cax11"` | Hetzner Cloud VM model used to build the ARM64 golden image snapshot. |
| `x86_builder` | `string` | `"cpx12"` | Hetzner Cloud VM model used to build the x86_64 golden image snapshot (requires 40GB disk). |
| `fallback_locations` | `list` | `["fsn1", "nbg1", "hel1"]` | Datacenter locations evaluated in priority order for building snapshots (snapshots are project-global). |

---

### `discord`

> [!TIP]
> For full instructions on creating the Discord Application, Workers VPC tunnel, and configuring slash commands, see the [Discord Bot Guide](../integrations/discord-bot/README.md).

| Parameter | Type | Default | Description |
|---|:---:|:---:|---|
| `enabled` | `bool` | `false` | Enable the serverless Discord slash-command bot on Cloudflare Workers. |
| `command_channel_id` | `string` | `""` | Optional Discord Channel ID (e.g. `#mc-commands`). When set, operational/admin commands (`/mc-start`, `/mc-stop`, `/mc-status`, `/mc-players`, `/mc-top`, `/mc-whitelist`, `/mc-backup`, `/mc-restart`, `/mc-logs`, `/mc-cmd`) are accepted only in this channel. |
| `chat_channel_id` | `string` | `""` | Optional Discord Channel ID (e.g. `#mc-chat`). When set, `/mc-say` is accepted only in this channel (keeping chat separate from server commands). |
| `allowed_user_ids` | `list` | `[]` | Optional list of Discord User IDs granted **Admin / Lifecycle** access (`/mc-start`, `/mc-stop`, `/mc-whitelist`, `/mc-backup`, `/mc-restart`, `/mc-cmd`). When empty `[]`, sensitive mutating admin commands (`/mc-whitelist`, `/mc-backup`, `/mc-restart`, `/mc-cmd`) **fail closed** (denied for all users) while `/mc-start`, `/mc-stop`, `/mc-say`, and read-only commands remain accessible to channel members. |

---

## 🤖 Automated Dependency Updates with Renovate

This repository is pre-configured to work seamlessly with **[Renovate](https://github.com/renovatebot/renovate)** to keep your Minecraft version, Docker containers, and GitHub Actions dependencies up to date without manual intervention.

### How Renovate Works Here
* **Minecraft Releases**: In `config/settings.yaml`, the comment `# renovate: datasource=mojang-java` instructs Renovate to monitor Mojang's official release metadata. When a new Minecraft version is published, Renovate opens a pull request.
* **Docker Containers**: The `# renovate: datasource=docker ...` annotations on `itzg/minecraft-server`, `itzg/mc-backup`, `cloudflare/cloudflared`, and `ghcr.io/bumuellp/mc-agent` allow Renovate to track all container updates.
* **GitHub Actions**: Workflows in `.github/workflows/` pinned to commit SHAs are automatically tracked and updated with commit notes.

### Installing Renovate on Your Repository
1. Navigate to the official [Renovate GitHub App](https://github.com/apps/renovate).
2. Click **Install** (or **Configure**).
3. Select your private Minecraft server repository under **Repository access**.
4. Renovate will automatically open an onboarding "Dependency Dashboard" Pull Request in your repository.
5. Merge the onboarding PR to enable automated dependency maintenance.
