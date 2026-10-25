# 🚀 Setup & Onboarding Guide

This guide walks you through configuring all required credentials, secrets encryption with Age/SOPS, and GitHub Actions to deploy your serverless Minecraft environment on Hetzner Cloud.

---

## 🗺️ The Setup Journey (The Red String)

To get your server up and running, follow this step-by-step sequence:

```
[ 1. Provider Accounts & Tokens ] ──> [ 2. Age & SOPS Encryption ] ──> [ 3. GitHub Secrets ] ──> [ 4. Settings Config ] ──> [ 5. Push & Launch ]
   (Hetzner, S3/R2, GitHub PAT)        (Local secrets.enc.yaml)        (SOPS_AGE_KEY in repo)       (config/settings.yaml)       (Run server-start.yml)
```

> [!IMPORTANT]
> **Need API tokens or provider accounts?**
> Before proceeding, ensure you have gathered your provider credentials. See the [Infrastructure & Provider Requirements Guide](INFRASTRUCTURE_PROVIDERS.md) for exact, click-by-click instructions on generating your Hetzner token, Cloudflare R2 / S3 credentials, and GitHub PAT.

---

## 📋 Prerequisites

Install these standard CLI tools on your workstation:

* **[age](https://github.com/FiloSottile/age)**: Modern, lightweight file encryption tool (`age`, `age-keygen`).
* **[SOPS](https://github.com/getsops/sops)** (`>= 3.9`): Secrets management CLI.
* **[OpenTofu](https://opentofu.org/)** (`>= 1.7.0`): *(Optional)* Only needed if running infrastructure plans locally outside of GitHub Actions.

---

## 🛠️ Step-by-Step Installation

### Step 1: Use This Template

Click **"Use this template"** on GitHub to create your own private repository from [mine-your-own-bum](https://github.com/bumuellp/mine-your-own-bum). Clone your new repository locally:

```bash
git clone git@github.com:<your-user>/<your-repo>.git
cd <your-repo>
```

---

### Step 2: Configure Secrets with SOPS and Age

SOPS automatically searches for Age private keys in the standard XDG path `~/.config/sops/age/keys.txt`.

#### Option A: Use an Existing Age Key
If you already use Age on your machine, retrieve your existing public key:
```bash
age-keygen -y ~/.config/sops/age/keys.txt
```
*(Alternatively, check the `# public key: age1...` comment inside `~/.config/sops/age/keys.txt`).*

#### Option B: Generate a New Age Key
If you are setting up Age for the first time, generate a dedicated keypair directly into the default SOPS directory:
```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```
*(If you already have a `keys.txt` file and want a dedicated keypair for this repository, append it with `age-keygen >> ~/.config/sops/age/keys.txt`).*

---

#### 1. Update `.sops.yaml`
Update `.sops.yaml` in your repository root with your public Age recipient key (`age1...`):
```yaml
creation_rules:
  - path_regex: config/secrets\.enc\.ya?ml$
    age: "age1YOUR_PUBLIC_KEY..."
```

#### 2. Generate OpenTofu State Encryption Passphrase
Generate a cryptographically secure passphrase for OpenTofu client-side state encryption (minimum 16 characters):
```bash
openssl rand -base64 32
```

#### 3. Create and Encrypt Configuration
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
   > `sops <file>` transparently decrypts the file in memory into your `$EDITOR` and re-encrypts it automatically upon saving. You never need to persist unencrypted plaintext files on disk.

3. Fill in your provider credentials (see [Infrastructure Providers Guide](INFRASTRUCTURE_PROVIDERS.md) for where to find each token):

| Secret Key | Required | Description |
|---|:---:|---|
| `hcloud_token` | **Yes** | Hetzner Cloud API token (Read & Write). See [Hetzner Setup](INFRASTRUCTURE_PROVIDERS.md#1-hetzner-cloud-required). |
| `rcon_password` | **Yes** | Secure password chosen by you for RCON administration and idle watchdog communication. |
| `console_password` | **Yes** | Secure password used, when logging in with the `root` user directly from hetzner cloud console. |
| `github_pat` | **Yes** | Scoped GitHub Fine-Grained Personal Access Token with repository `actions: write` scope. **Required** for the on-server idle watchdog daemon to trigger `server-stop.yml` when no players are online. *(Alternatively provide via GitHub Secret `PAT_WATCHDOG`)*. See [GitHub PAT Setup](INFRASTRUCTURE_PROVIDERS.md#3-github-personal-access-tokens-required). |
| `s3_bucket` | **Yes** | S3-compatible bucket name for OpenTofu remote state (e.g. Cloudflare R2 or Hetzner Object Storage). See [S3 Storage Setup](INFRASTRUCTURE_PROVIDERS.md#2-object-storage--s3-backend-required). |
| `s3_endpoint` | **Yes** | S3 API endpoint URL (e.g. `https://<account_id>.r2.cloudflarestorage.com` or `https://fsn1.your-objectstorage.com`). |
| `s3_access_key` | **Yes** | S3 API Access Key ID. |
| `s3_secret_key` | **Yes** | S3 API Secret Access Key. |
| `state_encryption_passphrase` | **Yes** | The generated OpenTofu state encryption passphrase (PBKDF2 + AES-GCM). |
| `dns_token` | *Optional* | deSEC API token or IONOS API key (`<public_prefix>.<secret>`). Required if `dns.enabled: true`. See [DNS Setup](INFRASTRUCTURE_PROVIDERS.md#4-dynamic-dns-provider-optional). |
| `cloudflare_api_token` | *Optional* | Cloudflare API token with `Workers:Edit` permissions. Required if Discord bot is enabled. See [Discord Bot Guide](../integrations/discord-bot/README.md). |
| `discord_public_key` | *Optional* | Discord Application Public Key (64 hex characters) for interaction verification. |
| `discord_application_id` | *Optional* | Discord Application ID. |
| `discord_bot_token` | *Optional* | Discord Bot Token for registering slash commands. |

4. Run pre-flight verification locally:
   ```bash
   ./scripts/preflight.sh
   ```
   > [!TIP]
   > This helper script decrypts your secrets in memory and validates live connectivity to the Hetzner Cloud API, DNS provider zone existence, S3 backend authentication, OpenTofu client-side state encryption, and validates all code and `.tftpl` templates (`tofu validate`) before triggering GitHub Actions.

5. Commit `config/secrets.enc.yaml` locally:
   ```bash
   git add .sops.yaml config/secrets.enc.yaml
   git commit -m "feat(secrets): initialize encrypted repository secrets"
   ```
   > [!WARNING]
   > **Do NOT push to GitHub yet!**
   > Keep your changes local for now. We still need to configure the required repository secret in GitHub (Step 3) and initialize your server settings (Step 4). Pushing prematurely will trigger CI before secrets are present.

---

### Step 3: Configure GitHub Repository Secrets

In your GitHub repository, navigate to **Settings > Secrets and variables > Actions** and configure the required repository secrets:

| Secret Name | Required | Description |
|---|:---:|---|
| `SOPS_AGE_KEY` | **Yes** | The private Age key (`AGE-SECRET-KEY-1...`) from `~/.config/sops/age/keys.txt`. GitHub Actions uses this to decrypt secrets in memory during workflow execution. |
| `PAT_WATCHDOG` | **Yes\*** | GitHub Fine-Grained PAT with `actions: write` scope for the idle watchdog daemon. \**Required unless provided in `config/secrets.enc.yaml` under `github_pat`*. |
| `PAT_TEMPLATE_SYNC` | *Optional* | GitHub Fine-Grained PAT with `actions`, `contents`, `pull-requests`, and `workflows` scopes to allow automated template sync PRs. |

> [!IMPORTANT]
> **Why `PAT_WATCHDOG` is required**:
> The auto-stop watchdog runs as a local systemd daemon on the Hetzner VM long after the startup GitHub Actions workflow has completed. Ephemeral `GITHUB_TOKEN` credentials expire when the workflow finishes. A persistent scoped PAT (stored in SOPS as `github_pat` or as a GitHub secret `PAT_WATCHDOG`) is required for the VM to trigger `server-stop.yml` when idle; without it, the server will remain running and incur ongoing compute costs.

---

### Step 4: Customize Server Settings

Initialize and edit your server specifications in `config/settings.yaml`:

```bash
cp config/settings.example.yaml config/settings.yaml
```

Adjust the server sizing, Minecraft version, mod list, and DNS parameters according to the [Configuration Reference](CONFIGURATION.md). Commit `config/settings.yaml` locally:

```bash
git add config/settings.yaml
git commit -m "feat(config): configure minecraft server settings"
```

---

### Step 5: (Optional) Local OpenTofu Execution

If you wish to test OpenTofu plans directly from your local terminal instead of via GitHub Actions:

```bash
cd iac
export TF_VAR_state_encryption_passphrase="YOUR_PASSPHRASE"
tofu init \
  -backend-config="bucket=<bucket>" \
  -backend-config="endpoint=<endpoint>" \
  -backend-config="access_key=<key>" \
  -backend-config="secret_key=<secret>"
tofu plan
cd ..
```

---

### Step 6: Push to GitHub & Launch Server

Now that your secrets, settings, and GitHub repository secrets are in place, push your commits to `main`:

```bash
git push origin main
```

> [!NOTE]
> Pushing to `main` triggers GitHub Actions CI validation (`.github/workflows/ci.yml`) to ensure your configurations are valid.

#### Launching the Server
Once CI succeeds, launch your Minecraft server:
1. Go to the **Actions** tab in your repository.
2. Select the **Start Minecraft Server** workflow.
3. Click **Run workflow** on `main`.
4. Follow along in the workflow logs. Once finished, check the **Job Summary** for your connection IP and domain!
