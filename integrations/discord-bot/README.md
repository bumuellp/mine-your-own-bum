# 🎮 Discord Slash-Command Bot (Rust + Cloudflare Workers)

A serverless Discord slash-command bot written in **Rust** using [`workers-rs`](https://github.com/cloudflare/workers-rs), compiled to WebAssembly, and hosted on **Cloudflare Workers** (100% free tier). It dispatches GitHub Actions workflows (`server-start.yml` and `server-stop.yml`) to provision and destroy your ephemeral Minecraft server on Hetzner Cloud.

---

## ⚡ Features

* **Zero JS/TS in Runtime**: 100% pure Rust compiled to WebAssembly (`.wasm`) using `edition = "2024"`.
* **Direct TCP Server Ping (Port 25565)**: Pings the server FQDN in real-time over TCP (`cloudflare:sockets`) to report actual connectivity and guard against starting an already-running server.
* **Instant Interaction Acknowledgement**: Uses Discord's deferred response pattern (`type: 5`) to comply with Discord's strict 3-second SLA while background TCP pings and workflow dispatches run.
* **Concurrency & Mutex Protection**: Inspects GitHub's Actions API to prevent duplicate starts or conflicts with ongoing workflows.
* **Role / User Access Control**: Restrict commands to specific Discord User IDs via `ALLOWED_USER_IDS`.
* **Zero 24/7 Hosting Costs**: Runs entirely on Cloudflare Workers (free tier includes 100,000 requests/day).

---

## 📋 Division of Responsibilities: Manual vs. CI Automated

| Responsibility | Type | Description |
|---|---|---|
| **Discord App & Bot Creation** | 🧑‍💻 **Manual (One-Time)** | Create application in Discord Developer Portal; copy `Application ID`, `Public Key`, and `Bot Token`. |
| **Bot Guild Invite** | 🧑‍💻 **Manual (One-Time)** | Invite bot to your Discord server using OAuth2 URL Generator (`bot`, `applications.commands`). |
| **Secrets Management (SOPS)** | 🧑‍💻 **Manual (One-Time)** | Encrypt Discord credentials & Cloudflare API token in `config/secrets.enc.yaml`. |
| **Link Interactions Endpoint** | 🧑‍💻 **Manual (One-Time)** | Set `Interactions Endpoint URL` in Discord Portal after first deployment. |
| **Rust Lint & Verification** | 🤖 **Automated (CI)** | Runs `cargo clippy`, `cargo fmt --check`, and `cargo check` on every pull request & push. |
| **Cloudflare Worker Build & Deploy** | 🤖 **Automated (CI)** | Compiles Rust to `.wasm` via `worker-build` and deploys to Cloudflare via `wrangler-action`. |
| **Worker Secrets Sync** | 🤖 **Automated (CI)** | Decrypts SOPS secrets via `SOPS_AGE_KEY` in CI and updates Worker secrets via Wrangler. |
| **Slash Command Registration** | 🤖 **Automated (CI)** | Executes `scripts/register-commands.sh` against Discord REST API on push to `main`. |

---

## 🛠️ Step-by-Step Manual Setup

### Step 1: Create a Discord Application (Manual)

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications) and log in.
2. Click **New Application** and name it (e.g., `Mine Your Own Bum`).
3. On the **General Information** page:
   - Copy the **Application ID**.
   - Copy the **Public Key** (used by the Rust worker to verify Ed25519 signatures).
4. Go to **Bot** in the left sidebar:
   - Click **Reset Token** and copy your **Bot Token** (used by `scripts/register-commands.sh`).
5. Go to **OAuth2 → URL Generator**:
   - Scopes: Select `bot` and `applications.commands`.
   - Bot Permissions: None required (or `Send Messages`).
   - Copy the generated URL and open it in a browser to invite the bot to your Discord server.

---

### Step 2: Store Secrets in SOPS (Manual)

Add the Discord and Cloudflare tokens to `config/secrets.enc.yaml` using SOPS:

```bash
sops config/secrets.enc.yaml
```

Add the following keys:
```yaml
discord_public_key: "<YOUR_DISCORD_PUBLIC_KEY>"
discord_application_id: "<YOUR_DISCORD_APPLICATION_ID>"
discord_bot_token: "<YOUR_DISCORD_BOT_TOKEN>"
cloudflare_api_token: "<YOUR_CLOUDFLARE_API_TOKEN>"
```

*(CI will automatically decrypt these using `SOPS_AGE_KEY` to deploy the worker and sync slash commands).*

---

### Step 3: Local Manual Deployment (Optional)

If deploying manually from your workstation instead of CI:

```bash
# 1. Authenticate with Cloudflare
export CLOUDFLARE_API_TOKEN="your_cloudflare_token"

cd integrations/discord-bot

# 2. Provision worker secrets in Cloudflare
npx wrangler secret put DISCORD_PUBLIC_KEY
npx wrangler secret put DISCORD_APPLICATION_ID
npx wrangler secret put GITHUB_PAT
npx wrangler secret put ALLOWED_USER_IDS  # Optional

# 3. Deploy Rust Worker to Cloudflare
npx wrangler deploy

# 4. Register slash commands
DISCORD_BOT_TOKEN="your_bot_token" DISCORD_APPLICATION_ID="your_app_id" ./scripts/register-commands.sh
```

---

### Step 4: Link Interactions URL in Discord (Manual, One-Time)

1. Return to the [Discord Developer Portal](https://discord.com/developers/applications) → select your application.
2. In the **General Information** tab, find **Interactions Endpoint URL**.
3. Paste your Cloudflare Worker URL:
   `https://minecraft-discord-bot.<your-subdomain>.workers.dev`
4. Click **Save Changes**.
   *Discord will send a test `PING` interaction with an Ed25519 signature. The Rust Worker will verify it and reply with `PONG`, displaying a green checkmark.*

---

## 🎯 Usage in Discord

In any channel your bot has access to:
* `/mc-status`: Pings the server FQDN on port 25565 and inspects GitHub Actions to report real-time status (Online, Offline, or In-Progress).
* `/mc-start`: Pings the server first; if offline, dispatches `server-start.yml` via GitHub Actions to provision the Hetzner VM and launch the server. If already online, notifies the caller without booting a duplicate node.
* `/mc-stop`: Pings the server first; if online, dispatches `server-stop.yml` to save chunks, upload cloud backup, and destroy the VM.
