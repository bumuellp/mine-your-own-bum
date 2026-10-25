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
- **Cost-Optimized Pay-Per-Play Model**: When stopped, compute costs drop to **€0.00/h**. Hetzner Cloud Firewalls are **100% free**. You only pay for the idle 10 GB persistent block volume (~€0.45/month).
- **Auto-Stop Idle Watchdog**: A background systemd daemon checks player count via RCON. If zero players are active for your configured idle timeout (`idle_timeout_minutes`), the server cleanly saves world data and dispatches a GitHub Action to destroy the VM.
- **Zero-Loss Graceful Teardown**: Both automated idle shutdowns and manual teardowns via `server-stop.yml` issue an ACPI power signal, allowing systemd and Docker to trap SIGTERM, cleanly flush world chunks via RCON, and unmount the filesystem before the VM is deleted.
- **Java & Bedrock Crossplay**: Powered by PaperMC with GeyserMC and Floodgate, allowing PC, mobile, and console players to play together seamlessly on standard ports (`25565` Java, `19132` Bedrock).
- **Dynamic DNS Integration**: Built-in support for **deSEC.io** and **IONOS Domain APIs** automatically publishes the server's public IPv4/IPv6 on start and removes it on shutdown.
- **Encrypted Secrets with SOPS + Age**: Keep API tokens safe directly inside your repository via GitOps encryption.
- **Client-Side State Encryption**: End-to-end client-side encryption of OpenTofu state and plan files on the S3-compatible backend using **PBKDF2** key derivation and **AES-GCM** encryption (`aes_gcm`). State data is never stored unencrypted in object storage.

---

## 🛠️ Quick Start & Setup Guide

### Prerequisites (Local Administrator)
To manage secrets and customize the server, install these standard CLI tools:
- **[age](https://github.com/FiloSottile/age)**: Key generator and encryption tool (`age`, `age-keygen`).
- **[SOPS](https://github.com/getsops/sops)** (`>= 3.9`): Secrets management CLI.
- **[OpenTofu](https://opentofu.org/)** (`>= 1.7.0`): *Optional*, only needed if running IaC plans locally outside GitHub Actions.

### 1. Use This Template
Click **"Use this template"** on GitHub to create your own private repository.

### 2. Configure Secrets with SOPS and Age

SOPS automatically looks for Age private keys in the standard XDG path `~/.config/sops/age/keys.txt`.

#### Option A: Use an Existing Age Key
If you already use Age on your machine, retrieve your existing public key:
```bash
age-keygen -y ~/.config/sops/age/keys.txt
```
*(Alternatively, check the `# public key: age1...` comment inside `~/.config/sops/age/keys.txt`).*

#### Option B: Generate a New Age Key
If you are setting up Age for the first time, generate a keypair directly into the default SOPS directory:
```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```
*(If you already have `keys.txt` and want a dedicated keypair for this repository, append it with `age-keygen >> ~/.config/sops/age/keys.txt`).*

---

#### Update `.sops.yaml`
Update `.sops.yaml` in the repository root with your public key (`age1...`):
```yaml
creation_rules:
  - path_regex: config/secrets\.enc\.ya?ml$
    age: "age1YOUR_PUBLIC_KEY..."
```

#### Generate OpenTofu State Encryption Passphrase
Generate a cryptographically secure passphrase for OpenTofu client-side state encryption (minimum 16 characters):
```bash
openssl rand -base64 32
```

#### Create and Encrypt Configuration
1. Initialize the encrypted secrets file from the template:
   ```bash
   cp config/secrets.example.yaml config/secrets.enc.yaml
   sops --encrypt --in-place config/secrets.enc.yaml
   ```
2. Open and edit your secrets safely in your `$EDITOR`:
   ```bash
   sops config/secrets.enc.yaml
   ```
   > [!TIP]
   > `sops <file>` transparently decrypts the file in memory into your `$EDITOR` and re-encrypts it automatically on save. You never need to keep unencrypted plaintext files on disk.

3. Fill in your provider credentials:
   - `hcloud_token`: Hetzner Cloud API token
   - `rcon_password`: Secure RCON password
   - `github_pat`: Scoped GitHub Personal Access Token with repository `actions: write` scope (for VM idle watchdog auto-stop). Alternatively configure via GitHub Secret `PAT_WATCHDOG`.
   - `dns_token`: deSEC API Token or IONOS API Key (note: IONOS keys must be in `<public_prefix>.<secret>` format separated by a dot)
   - `s3_bucket`, `s3_endpoint`, `s3_access_key`, `s3_secret_key`: S3 backend configuration for OpenTofu state storage
   - `state_encryption_passphrase`: The generated OpenTofu state encryption passphrase

4. Run pre-flight verification:
   ```bash
   ./scripts/preflight.sh
   ```
   > [!TIP]
   > This helper script decrypts your secrets in memory and verifies live connectivity to the Hetzner Cloud API, DNS provider zone existence, S3 backend authentication, OpenTofu client-side state encryption, and validates all code and `.tftpl` templates (`tofu validate`) before triggering GitHub Actions.

5. Commit `config/secrets.enc.yaml` to Git.

### 3. Configure GitHub Repository Secrets

Under your repository's **Settings > Secrets and variables > Actions**, add the required secrets:

| Secret | Required | Description |
| :--- | :---: | :--- |
| `SOPS_AGE_KEY` | **Yes** | Private Age key (`AGE-SECRET-KEY-1...`) from `~/.config/sops/age/keys.txt` used by CI to decrypt secrets and manage state |
| `PAT_WATCHDOG` | *Optional* | Fine-grained GitHub PAT with repository `actions: write` scope for the VM idle watchdog to trigger `server-stop.yml`. *Can alternatively be supplied in `secrets.enc.yaml` as `github_pat`*. |
| `PAT_TEMPLATE_SYNC` | *Optional* | GitHub PAT with `repo` and `workflow` scopes to allow automated template sync PRs to update `.github/workflows/` (defaults to `GITHUB_TOKEN`) |

> [!NOTE]
> **Why `PAT_WATCHDOG` cannot use the default GitHub Actions token**:
> The auto-stop watchdog runs as a local systemd daemon on the Hetzner VM long after the startup workflow has finished. Ephemeral GitHub Actions tokens expire upon workflow completion and cannot be used by the VM. Providing a scoped token (in SOPS or as a GitHub secret) is required for the VM to trigger `server-stop.yml` on idle.

> [!TIP]
> **All provider tokens and remote state credentials live in SOPS!**
> Tokens like `hcloud_token`, `dns_token`, `rcon_password`, S3 backend credentials (`s3_bucket`, `s3_endpoint`, `s3_access_key`, `s3_secret_key`), and `state_encryption_passphrase` are stored directly in `config/secrets.enc.yaml` and decrypted automatically during workflow runs.

#### Local OpenTofu Execution
If you run OpenTofu commands locally from the `iac/` directory instead of GitHub Actions:
```bash
export TF_VAR_state_encryption_passphrase="YOUR_PASSPHRASE"
tofu init -backend-config="bucket=..." -backend-config="endpoint=..." -backend-config="access_key=..." -backend-config="secret_key=..."
tofu plan
```

### 4. Customize Server Settings

Copy and adjust `config/settings.yaml`:
```bash
cp config/settings.example.yaml config/settings.yaml
```

Edit `config/settings.yaml` with your preferred server specifications and commit it to Git:
```yaml
server:
  server_type: "cax21"         # 4 vCPU ARM, 8 GB RAM (~€0.017/hour)
  location: "fsn1"             # Falkenstein, Germany (or nbg1, hel1)
  volume_size_gb: 10           # Persistent block volume
  always_on: false             # Set to true to disable auto-stop
  idle_timeout_minutes: 15     # Auto-stop after 15m of no players
  keyboard_layout: "de"        # Console keyboard layout ("de", "us", etc.)
  ssh_keys:                    # Hetzner SSH key names (suppresses password emails)
    - "your-ssh-key-name"
  ssh_allowed_ips: []          # Whitelist CIDRs for SSH or [] to drop TCP 22

minecraft:
  server_type: "FABRIC"        # "FABRIC" (vanilla mechanics) or "PAPER"
  version: "26.3"              # Minecraft release version
  jvm_memory: "6G"             # Java heap allocation (leaves ~2GB for OS & Geyser on 8GB node)
  motd: "Mine Your Own Bum"
  max_players: 20
  difficulty: "normal"
  online_mode: true            # Mojang session authentication (set false for offline/LAN servers)
  enforce_secure_profile: true # Require signed player chat profiles
  whitelist_enabled: true      # Enforce player whitelist
  whitelist:
    - "Steve"                  # Java username or Bedrock Floodgate UUID
  ops:
    - "Steve"                  # Server operator (permission level 4)
  modrinth_projects:           # Fabric mods loaded dynamically from Modrinth
    - "fabric-api"
    - "lithium"
    - "ferrite-core"
    - "krypton"
    - "carpet"
    - "geyser"
    - "floodgate"
  plugins: []                  # Direct jar URLs (used for Spigot/Paper plugins)

dns:
  enabled: true
  provider: "desec"            # "desec" or "ionos"
  domain: "example.com"        # Registered apex / zone domain
  subname: "mc"                # Subdomain prefix (e.g. mc.example.com)
  ttl: 60

discord:
  enabled: false               # Deploy serverless slash bot on Cloudflare Workers
  allowed_user_ids: []         # Optional: Restrict /mc-start and /mc-stop to user IDs
```
Commit `config/settings.yaml` to your repository so GitHub Actions can read your configuration.

#### ⚙️ Configuration Reference (`config/settings.yaml`)

##### `server`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `server_type` | `string` | `"cax21"` | Hetzner Cloud VM model (e.g. `cax21`, `cpx22`, `cpx32`). `cax21` (4 vCPU ARM Ampere, 8 GB RAM) is recommended for smooth Paper chunk generation and cost efficiency. |
| `location` | `string` | `"fsn1"` | Hetzner datacenter location (`fsn1` = Falkenstein, `nbg1` = Nuremberg, `hel1` = Helsinki). *Note: Persistent volumes are currently available in EU regions.* |
| `volume_size_gb` | `number` | `10` | Size of the persistent Hetzner block volume retaining Minecraft world data across shutdowns (minimum 10 GB). |
| `always_on` | `bool` | `false` | When `true`, disables the auto-stop watchdog; the VM stays running until stopped manually via workflow. |
| `idle_timeout_minutes` | `number` | `15` | Minutes with 0 active players before saving the world and triggering automated VM teardown. |
| `keyboard_layout` | `string` | `"de"` | Virtual console keyboard layout (`"de"`, `"us"`, `"uk"`, etc.) loaded automatically on boot. |
| `use_golden_image` | `bool` | `false` | When `true`, provisions the server using a pre-baked Hetzner snapshot image created by Packer (containing pre-cached Docker images and keyboard layout), reducing cold startup time by ~45 seconds. When `false`, uses the base `docker-ce` image. |
| `ssh_keys` | `list` | `[...]` | List of SSH key names/IDs in your Hetzner Cloud project. Attaching at least one key suppresses root password emails from Hetzner. |
| `ssh_allowed_ips` | `list` | `[]` | Whitelist of IPv4/IPv6 CIDR ranges allowed to connect via SSH port 22 (e.g. `["203.0.113.50/32"]`). Leave empty `[]` to drop all port 22 traffic. |

##### `minecraft`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `server_type` | `string` | `"FABRIC"` | Minecraft server implementation (`"FABRIC"` for 100% vanilla redstone/farm mechanics, or `"PAPER"`). |
| `version` | `string` | `"26.3"` | Target Minecraft version (e.g. `"26.3"`, `"LATEST"`). |
| `jvm_memory` | `string` | `"6G"` | Java heap memory allocation (`-Xmx`). Aikar's GC flags are applied automatically for optimal pause times. |
| `motd` | `string` | `"..."` | Message of the day displayed in the multiplayer server list. |
| `max_players` | `number` | `20` | Maximum simultaneous players allowed. |
| `difficulty` | `string` | `"normal"` | In-game difficulty (`peaceful`, `easy`, `normal`, `hard`). |
| `online_mode` | `bool` | `true` | When `true`, authenticates connecting players against Mojang session servers. Set to `false` for offline or LAN-only play. |
| `enforce_secure_profile` | `bool` | `true` | When `true`, requires players to have a Mojang-signed public key / secure chat profile. Set `false` if using offline mode or clients without signed profiles. |
| `whitelist_enabled` | `bool` | `true` | When `true`, enforces native player access control. Unauthorized players cannot connect. |
| `whitelist` | `list` | `[...]` | Whitelisted players. Java players use username (e.g. `"Steve"`). Bedrock players use Floodgate UUIDs (e.g. `"00000000-0000-0000-xxxx-xxxxxxxxxxxx"` derived from Xbox XUID). |
| `ops` | `list` | `[...]` | Server operators granted permission level 4 (`/gamemode`, `/fwhitelist`, `/kick`, etc.). Format matches `whitelist`. |
| `modrinth_projects` | `list` | `[...]` | Fabric mods resolved and downloaded from Modrinth automatically on boot (e.g. `fabric-api`, `lithium`, `carpet`, `geyser`, `floodgate`). |
| `plugins` | `list` | `[]` | HTTP/HTTPS direct download URLs for jar plugins (primarily for Paper servers or standalone jars). |

##### `dns`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `enabled` | `bool` | `false` | Enable automated public DNS registration on boot and cleanup on shutdown. |
| `provider` | `string` | `"desec"` | DNS provider API (`"desec"` or `"ionos"`). |
| `domain` | `string` | `"..."` | Your registered **apex / zone domain** in your DNS provider (e.g. `"example.com"` or `"my-server.dedyn.io"`). |
| `subname` | `string` | `"mc"` | Subdomain prefix (e.g. `"mc"` or `"mine-your-own-bum"`). Use `""` or `"@"` for apex root domain. |
| `ttl` | `number` | `60` | DNS record TTL in seconds (low value like `60` recommended for ephemeral IPs). |

##### `backup`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `enabled` | `bool` | `false` | Enable automated off-site cloud backups to Cloudflare R2 / S3 via `mc-backup` sidecar. |
| `retention_count` | `number` | `10` | Number of recent backups to keep. Automatically prunes older backups both locally and in remote R2 storage. |
| `interval` | `string` | `"1h"` | Interval between recurring snapshots while the server is actively running. |
| `initial_delay` | `string` | `"5m"` | Delay after boot before taking the first baseline snapshot. |

##### `containers`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `minecraft_server` | `string` | `"itzg/minecraft-server:2026.10.0"` | Docker image tag for the Minecraft server container. Tracked and updated automatically by Renovate. |
| `backup` | `string` | `"itzg/mc-backup:2026.10.1"` | Docker image tag for the Rclone backup sidecar container. Tracked and updated automatically by Renovate. |

##### `discord`
| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `enabled` | `bool` | `false` | Enable the serverless Discord slash-command bot on Cloudflare Workers. See the [Discord Bot Guide](integrations/discord-bot/README.md). |
| `allowed_user_ids` | `list` | `[]` | Optional list of Discord User IDs permitted to manage the server (`/mc-start`, `/mc-stop`). Leave empty `[]` to allow all members in your guild. |

#### 🛡️ Player Access Control & Whitelisting (Crossplay)

When `whitelist_enabled: true` is configured, only authorized players can connect to the server:
* **Java Edition Players**: Add standard Minecraft usernames (e.g. `"Steve"`). The server container resolves Mojang UUIDs automatically.
* **Bedrock Edition Players (Geyser / Floodgate)**: Because Mojang APIs do not index Xbox Gamertags, Bedrock players use deterministic Floodgate UUIDs (`00000000-0000-0000-xxxx-xxxxxxxxxxxx` derived from their numeric Xbox User ID).

There are three ways to obtain the Floodgate UUID or whitelist Bedrock players:

##### 1. Built-in Helper Script (Fastest for Git Config)
Run the included helper script to resolve any Xbox Gamertag into its Floodgate UUID:
```bash
./scripts/get-bedrock-uuid.sh <Gamertag>
```
Output:
```text
Gamertag:       Alex
Xbox XUID:      2535412345678901
Floodgate UUID: 00000000-0000-0000-0009-011234567890

Add to config/settings.yaml:
  whitelist:
    - "00000000-0000-0000-0009-011234567890"  # .Alex (Bedrock)
```

##### 2. Web Lookup Tools
Look up Gamertags and Floodgate UUIDs online via public profile tools:
* [CraftMC Player Lookup](https://craftmc.net): Search by Xbox Gamertag to view profile details, XUID, and Floodgate UUID.
* [mc-api.io](https://mc-api.io): Cross-edition player profile and UUID resolver.

##### 3. In-Game Whitelist Management (While Playing)
If you or another player is already configured as an operator (`ops`), you can manage players directly in-game without editing Git files:
* **Native Floodgate Command**: Run `/fwhitelist add <Gamertag>` in-game or via console. Floodgate automatically resolves the player and writes them to `whitelist.json` on the persistent storage volume.
* **Temporary First-Join Workaround**:
  1. Temporarily pause the whitelist: `/whitelist off`
  2. Have the Bedrock friend connect to the server once (allowing Geyser/Floodgate to register their profile).
  3. Add them: `/whitelist add .<Gamertag>` (or `/fwhitelist add <Gamertag>`).
  4. Re-enable the whitelist: `/whitelist on`. All changes persist across server restarts.

---

## 🚀 Starting and Stopping the Server

### Starting
1. Go to the **Actions** tab in GitHub.
2. Select **Start Minecraft Server**.
3. Click **Run workflow**.
4. The workflow runs automated pre-flight checks (`./scripts/preflight.sh`) to validate all credentials, S3 backend connectivity, and DNS zones before provisioning.
5. Once provisioned, a TCP healthcheck polls port `25565` to confirm Minecraft is online before completing.
6. Once completed, the **Job Summary** displays:
   - Server Public IPv4 / IPv6
   - Full DNS Domain (FQDN)
   - Connection URLs for Java (`mc.example.com:25565`) and Bedrock (`mc.example.com:19132`)

### Stopping
- **Automatic**: Stop occurs automatically when no players are connected for `idle_timeout_minutes` (the watchdog flushes world chunks via RCON and dispatches teardown).
- **Manual**: Go to **Actions > Stop Minecraft Server > Run workflow** (dispatches an ACPI shutdown signal to flush dirty chunks and unmount storage before destroying the VM).

---

## 🎮 How to Connect (Clients)

No client-side mods are required to join. Both Java Edition and Bedrock Edition players can play together simultaneously on the same server.

### ☕ Minecraft Java Edition (PC, Mac, Linux)
1. Open the official **Minecraft Launcher** (or Prism Launcher, Modrinth App).
2. Launch Minecraft matching the server version (e.g. `1.21.x`).
3. Go to **Multiplayer > Add Server**.
4. Enter your connection details:
   - **Server Name**: Any name (e.g. `Mine Your Own Bum`)
   - **Server Address**: Your configured FQDN domain (e.g. `mc.example.com`), or the temporary public IPv4 address from the workflow Job Summary. Default port `25565` does not need to be specified.
5. Click **Done** and connect.

### 📱 Minecraft Bedrock Edition (Windows 10/11, iOS, Android)
1. Launch **Minecraft (Bedrock)**.
2. Go to **Play > Servers tab > Add Server** (scroll down to the bottom of the server list).
3. Fill in:
   - **Server Name**: `Mine Your Own Bum`
   - **Server Address**: Your configured domain (or server IPv4)
   - **Port**: `19132` (standard Bedrock UDP port)
4. Tap **Save** and select the server to join.

### 🕹️ Consoles (Xbox, PlayStation, Nintendo Switch)
Console editions of Minecraft Bedrock do not include an "Add External Server" button by default due to platform restrictions. You can easily connect using one of the following methods:

- **Recommended (Easiest)**: Download the free **[BedrockTogether](https://bedrocktogether.net/)** app on an iOS or Android smartphone connected to the same Wi-Fi as your console:
  1. Enter your server's domain/IP and port `19132` in the app and tap **Run**.
  2. On your console, open Minecraft and navigate to **Friends > LAN Games**.
  3. The server will appear automatically as a joinable local game!
- **Alternative**: Configure DNS redirection via public tools like BedrockConnect or MC-Server-Connector.

---

## 🧪 Automated Testing & Continuous Verification

- **Fail-Fast Pre-Flight Verification**: Run `./scripts/preflight.sh` locally or let GitHub Actions run it as a gatekeeper on server startup to validate Hetzner tokens, OpenTofu state encryption, DNS records, and template syntax in under 10 seconds.
- **Container Smoke Testing**: Pull requests updating `iac/templates/docker-compose.yml.tftpl` or server configs (such as Renovate bumping `itzg/minecraft-server`) trigger an automated container test (`.github/workflows/container-smoke-test.yml`). It renders the stack, spins up a test container, and verifies RCON communication before merging.
- **Packer Golden Machine Images**: Build a pre-cached Hetzner Cloud snapshot image (`.github/workflows/packer-build.yml`) running a temporary ARM `cax11` builder instance to pull container images and configure keymaps ahead of time. Older snapshots with label `role=minecraft-golden-image` are automatically rotated so only a single snapshot is kept in your Hetzner Cloud project.

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
