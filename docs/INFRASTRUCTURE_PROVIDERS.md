# ☁️ Infrastructure & Provider Requirements

Before configuring the server, you need accounts and API credentials from your cloud infrastructure providers. This guide provides exact, click-by-click instructions on where to navigate and what to generate.

---

## 🗺️ Provider Choices at a Glance

| Component | Role | Supported Providers | Cost |
|---|---|---|:---:|
| **Compute & Persistent Storage** *(Required)* | Ephemeral ARM VM & persistent 10 GB block volume | [Hetzner Cloud](#1-hetzner-cloud-required) | ~€0.45/month idle, ~€0.017/hour running |
| **Object Storage Backend** *(Required)* | Remote OpenTofu state & optional world backups | [Cloudflare R2](#choice-a-cloudflare-r2-recommended--free) *(Free)*, [Hetzner Object Storage](#choice-b-hetzner-object-storage-native-integration), or [AWS S3](#choice-c-aws-s3--compatible-s3) | Free tier or ~€5.95–€7.00/month |
| **Automation Tokens** *(Required)* | Triggers automated shutdown when idle | [GitHub Fine-Grained Personal Access Token (PAT)](#3-github-personal-access-tokens-required) | Free |
| **Dynamic DNS** *(Optional)* | Auto-registers domain name on start | [deSEC.io](#choice-a-desecio-free-automated-dnssec) *(Free)*, [IONOS](#choice-b-ionos-developer-api), or [Hetzner DNS](#choice-c-hetzner-domains--dns) | Free / Included with domain |
| **Discord Bot** *(Optional)* | Serverless slash-command bot | [Discord Developer Portal](#5-discord-application-optional) & Cloudflare | Free tier |

---

## 1. Hetzner Cloud *(Required)*

Hetzner Cloud provides the compute virtual machine and persistent block volume.

1. Log into the [Hetzner Cloud Console](https://console.hetzner.cloud/).
2. Click **New Project** and name it (e.g. `minecraft-server`).
3. Select your new project.

### Generate Hetzner API Token (`hcloud_token`)
1. In the left navigation, go to **Security > API Tokens**.
2. Click **Generate API Token**.
3. Description: `mine-your-own-bum-ci`.
4. Permissions: Select **Read & Write** (required to provision, attach volumes, and destroy VMs).
5. Click **Generate API Token** and copy the token immediately. Store it securely; you will add this to `config/secrets.enc.yaml`.

### Add SSH Key (`server.ssh_keys`)
Adding an SSH key suppresses root password emails whenever an ephemeral VM boots:
1. In the left navigation, go to **Security > SSH Keys**.
2. Click **Add SSH Key**.
3. Paste your public key (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`).
4. Give it a memorable name (e.g., `admin-key`).
5. In `config/settings.yaml`, set `server.ssh_keys: ["admin-key"]`.

---

## 2. Object Storage / S3 Backend *(Required)*

OpenTofu requires an S3-compatible bucket to store its client-side encrypted state files (`terraform.tfstate`). This state is encrypted with PBKDF2 + AES-GCM before it ever leaves your runner.

> [!TIP]
> **Dedicated Backups Bucket**:
> If you plan to enable automated off-site backups (`backup.enabled: true`), you can reuse the same S3 credentials or create a second dedicated bucket (e.g. `minecraft-backups`) by repeating the bucket creation steps below.

### Choice A: Cloudflare R2 *(Recommended — Free Tier)*
Cloudflare R2 is 100% S3-compatible, offers 10 GB free monthly storage, and charges **$0.00 in egress bandwidth fees**.

1. Log into the [Cloudflare Dashboard](https://dash.cloudflare.com/).
2. In the left sidebar, navigate to **R2 Object Storage**.
3. Click **Create Bucket**:
   * Name: e.g. `minecraft-state` (must be lowercase).
   * Location: Automatic or Western Europe.
   * Click **Create Bucket**.
4. Retrieve your **S3 API Endpoint**:
   * On the bucket overview page, look under **Bucket Details** for the **S3 API URL** (or on the main R2 page under **Account Details** for your **Account ID**).
   * Format: `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`
5. Generate **R2 API Token** (`s3_access_key` & `s3_secret_key`):
   * On the main R2 overview page, click **Manage R2 API Tokens** in the right sidebar.
   * Click **Create API Token**.
   * Token name: `opentofu-state`.
   * Permissions: **Object Read & Write**.
   * Specify bucket: Apply to specific bucket (`minecraft-state`) or all buckets.
   * Click **Create API Token**.
   * Copy the **Access Key ID** and **Secret Access Key**.

### Choice B: Hetzner Object Storage *(Native Integration)*
Hetzner provides native S3-compatible Object Storage co-located directly in the same datacenters as your server (Falkenstein `fsn1`, Nuremberg `nbg1`, or Helsinki `hel1`).

> [!NOTE]
> **Cost Caveat**: Hetzner Object Storage has a fixed base cost of ~€5.95 to ~€7.00/month (for 1 TB storage with 1 TB egress included). While not free like Cloudflare R2, it offers the lowest latency to your Hetzner VM, keeps everything under a single provider invoice, and the 1 TB quota can be shared and reused across other personal projects.

1. In the Hetzner Cloud Console, navigate to **Storage > Object Storage**.
2. Click **Create Bucket**:
   * Choose the location matching your server (e.g. `fsn1`).
   * Name: `minecraft-state`.
3. Note your S3 API Endpoint:
   * Format: `https://<location>.your-objectstorage.com` (e.g. `https://fsn1.your-objectstorage.com`).
4. Under **Manage Keys** (or **S3 Credentials**), generate an access keypair:
   * Copy the **Access Key** (`s3_access_key`) and **Secret Key** (`s3_secret_key`).

### Choice C: AWS S3 / Compatible S3
If using Amazon Web Services:
1. Create a private bucket in your chosen region (e.g. `eu-central-1`).
2. Block all public access.
3. In IAM, create an automation user with `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` permissions for the bucket.
4. Endpoint format: `https://s3.<region>.amazonaws.com`.

---

## 3. GitHub Personal Access Tokens *(Required)*

Both tokens below use GitHub **Fine-Grained Personal Access Tokens** for least-privilege security.

### A. Watchdog Auto-Stop PAT (`github_pat` / `PAT_WATCHDOG`) *(Required)*

When no players are online for `idle_timeout_minutes`, the systemd watchdog running on the Hetzner VM triggers the `server-stop.yml` workflow via the GitHub REST API.

Because the GitHub Actions startup workflow completes shortly after boot, ephemeral GitHub tokens expire. A persistent scoped PAT is **required** so the VM can call GitHub Actions when idle:

1. In GitHub, click your profile picture in the top-right corner $\rightarrow$ **Settings**.
2. In the left sidebar, click **Developer Settings** (at the very bottom).
3. Under **Personal access tokens**, click **Fine-grained tokens**.
4. Click **Generate new token**.
5. Token name: `mine-your-own-bum-watchdog`.
6. Expiration: 90 days or 1 year.
7. Repository access: **Only select repositories** $\rightarrow$ Select your Minecraft server repository.
8. Permissions: Expand **Repository permissions**:
   * **Actions**: Select **Read and write** (allows dispatching workflows).
9. Click **Generate token** and copy the token.
10. Supply this value in `config/secrets.enc.yaml` under `github_pat` (or as a GitHub repository secret `PAT_WATCHDOG`).

### B. Template Sync PAT (`PAT_TEMPLATE_SYNC`) *(Optional)*

The weekly template synchronization workflow (`template-sync.yml`) checks upstream `mine-your-own-bum` for updates and opens Pull Requests.

Create this token the **exact same way** as the Watchdog token above, but configure the following permissions instead:
1. Under **Developer Settings > Personal access tokens > Fine-grained tokens**, click **Generate new token**.
2. Token name: `mine-your-own-bum-template-sync`.
3. Repository access: **Only select repositories** $\rightarrow$ Select your Minecraft server repository.
4. Permissions: Expand **Repository permissions**:
   * **Actions**: Select **Read and write**
   * **Contents**: Select **Read and write** (allows committing upstream changes to sync branches)
   * **Pull requests**: Select **Read and write** (allows opening sync PRs)
   * **Workflows**: Select **Read and write** (allows updating `.github/workflows/` files)
5. Generate and add this token as a GitHub repository secret named `PAT_TEMPLATE_SYNC`.

---

## 4. Dynamic DNS Provider *(Optional)*

If you set `dns.enabled: true` in `config/settings.yaml`, the server registers its new dynamic IPv4 and IPv6 addresses on boot and removes them on shutdown.

### Choice A: deSEC.io *(Free, Automated DNSSEC)*
1. Register for a free account at [desec.io](https://desec.io/).
2. Add a domain (e.g. `yourname.dedyn.io` or register your own custom domain).
3. In the deSEC console, go to **Token Management > Create new token**.
4. Copy the generated API token (`dns_token`).
5. In `config/settings.yaml`:
   ```yaml
   dns:
     enabled: true
     provider: "desec"
     domain: "yourname.dedyn.io"
     subname: "" # leave empty for apex
   ```

### Choice B: IONOS Developer API
> [!IMPORTANT]
> **One-Time Free API Activation**:
> Before generating keys in the IONOS Developer Portal, you must activate the **Developer API** feature in your IONOS Cloud Panel or Hosting Control Panel. It costs **€0.00 (completely free)**, but requires a one-click activation in your contract to enable API capabilities.

1. Activate the Developer API in your IONOS account.
2. Navigate to the [IONOS Developer Portal](https://developer.hosting.ionos.com/).
3. In the top navigation, click **API Keys**.
4. Click **Create Key**.
5. Enter a key name (e.g. `minecraft-ddns`).
6. Copy both the **Public Prefix** and the **Secret**.
7. Join them with a single dot (`.`):
   ```text
   <PUBLIC_PREFIX>.<SECRET>
   ```
   This combined string is your `dns_token` in `config/secrets.enc.yaml`.
8. In `config/settings.yaml`:
   ```yaml
   dns:
     enabled: true
     provider: "ionos"
     domain: "your-domain.com"
     subname: "mc"
   ```

### Choice C: Hetzner Domains & DNS
Hetzner integrates DNS management directly into the Hetzner Cloud Console under **DNS Zones**.

1. In the [Hetzner Cloud Console](https://console.hetzner.cloud/), navigate to your project and select **DNS Zones** (or create a zone if not already present).
2. Ensure your domain's nameservers are pointed to Hetzner's nameservers (`hydrogen.ns.hetzner.com`, `oxygen.ns.hetzner.com`, `helium.ns.hetzner.de`).
3. Under **Security > API Tokens**, use your existing project API token or click **Generate API Token** with **Read & Write** permissions.
4. Set `dns_token` in `config/secrets.enc.yaml` to this token (you can use the same token as `hcloud_token`).
5. In `config/settings.yaml`:
   ```yaml
   dns:
     enabled: true
     provider: "hetzner"
     domain: "your-domain.com"
     subname: "mc" # or "" / "@" for apex root
   ```
6. The startup workflow automatically provisions and syncs `A` (IPv4) and `AAAA` (IPv6) records via the official `hcloud` CLI, and tears them down when the server stops.

---

## 5. Discord Application *(Optional)*

> [!WARNING]
> **Do not push `discord.enabled: true` yet!**
> Keep `discord.enabled: false` in `config/settings.yaml` until you have finished all steps in the Discord bot guide and populated all Discord secrets in SOPS. Pushing `discord.enabled: true` prematurely will cause the deployment workflow to fail due to missing credentials.

To control your server via Discord slash commands (`/mc-start`, `/mc-stop`, `/mc-status`):
* Create a Discord Application in the [Discord Developer Portal](https://discord.com/developers/applications).
* Generate a Worker-scoped API token in Cloudflare Workers.
* Follow the dedicated, step-by-step [Discord Bot Setup Guide](../integrations/discord-bot/README.md).
