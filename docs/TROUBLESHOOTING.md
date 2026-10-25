# 🩺 Troubleshooting & Operational FAQ

This guide documents common quirks, diagnostic steps, and solutions when operating your on-demand Minecraft server.

---

## 🖥️ Server Access, Console & Log Inspection

### ⚠️ How to Access the Server via Hetzner Virtual Console & View Logs

If the Minecraft server is unreachable or failing during boot, you can access the server directly without network connectivity using Hetzner's out-of-band virtual console:

1. **Open Hetzner Virtual Console**:
   * In the [Hetzner Cloud Console](https://console.hetzner.cloud/), navigate to your project and select your active server.
   * In the top-right corner, click the **Console** icon (or go to **Actions > Console**).
2. **Log In**:
   * Username: `root`
   * Password: The root password configured via SOPS secrets (`console_password`), or log in via SSH port 22 if your IP is whitelisted under `server.ssh_allowed_ips` in `config/settings.yaml`.
3. **Inspect Minecraft Docker Container Logs**:
   All Docker Compose stacks, volumes, and server configurations reside in `/opt/minecraft`:
   ```bash
   cd /opt/minecraft

   # View live log stream:
   sudo docker compose logs -f

   # View last 100 lines:
   sudo docker compose logs --tail 100
   ```
4. **Check Systemd & Cloud-Init Logs**:
   If the Docker stack has not started, inspect initialization services:
   * **Cloud-Init Output Log** (provisioning & volume formatting):
     ```bash
     cat /var/log/cloud-init-output.log
     ```
   * **Idle Watchdog Daemon**:
     ```bash
     sudo journalctl -u mc-idle-watchdog -f
     ```
   * **Docker Daemon Service**:
     ```bash
     sudo journalctl -u docker -f
     ```

---

## 🗄️ OpenTofu Infrastructure & State Locks

### ⚠️ Error Acquiring State Lock (`tofu force-unlock`)

#### Symptom
A workflow run (`server-start.yml` or `server-stop.yml`) fails during `tofu apply` or `tofu destroy` with an error:
```text
Error acquiring the state lock: ConditionalCheckFailedException
Lock Info:
  ID:        1729828374-abcd-ef01-2345-6789abcdef01
  Path:      terraform.tfstate
  Operation: OperationTypeApply
  Who:       runner@github-actions...
```

#### Why This Happens
OpenTofu uses state locking to prevent concurrent workflows from corrupting the infrastructure state. If a previous workflow was cancelled mid-execution, aborted by a runner timeout, or suffered a network interruption before releasing the lock, the lock record remains in your S3/R2 backend.

#### Solution

##### Step 1: Ensure No Workflow is Running
Check the **Actions** tab in GitHub to ensure no other `Start Minecraft Server` or `Stop Minecraft Server` workflow is currently in progress.

##### Step 2: Release the Lock
* **Method 1: Local Terminal via `tofu force-unlock`**:
  Run from your workstation inside the `iac/` directory using the lock ID from the error message:
  ```bash
  cd iac
  export TF_VAR_state_encryption_passphrase="YOUR_PASSPHRASE"
  tofu init \
    -backend-config="bucket=<bucket>" \
    -backend-config="endpoint=<endpoint>" \
    -backend-config="access_key=<key>" \
    -backend-config="secret_key=<secret>"

  tofu force-unlock <LOCK_ID>
  ```
* **Method 2: Remove Lock File via S3/R2 Dashboard**:
  Log into your Cloudflare Dashboard (or AWS S3 / Hetzner Storage Console), open your bucket, and delete the lock object (typically named `terraform.tfstate.tflock` or `.tflock`).

---

## 📦 Machine Images & Architecture Mismatch

### ⚠️ Golden Image Builder Architecture Mismatch (`exec format error`)

#### Symptom
After enabling `server.use_golden_image: true`, the Minecraft container fails to start, systemd reports `Exec format error`, or the VM crashes on boot.

#### Why This Happens
Hetzner Cloud provides two distinct CPU architectures:
* **ARM64 (Ampere Altra)**: Server models starting with `cax` (e.g. `cax11`, `cax21`).
* **x86_64 (Intel / AMD)**: Server models starting with `cx` or `cpx` (e.g. `cx22`, `cpx21`).

The Packer golden image workflow (`.github/workflows/packer-build.yml`) defaults to an ARM64 builder instance (`cax11`) that pulls `linux/arm64` container images. If you configure an x86 server type (e.g. `cpx21` or `cx22`) in `config/settings.yaml` while booting from an ARM snapshot, binaries cannot execute due to architecture incompatibility.

#### Solution
* **Recommended (Stay on ARM64)**: Keep `server_type: "cax21"` in `config/settings.yaml`. The ARM `cax21` model (4 vCPU, 8 GB RAM) offers the best performance-per-euro for Minecraft Paper/Fabric servers.
* **If Using x86 Hardware**: If you must use an x86 server type (e.g. `cpx22`), either:
  1. Temporarily disable golden images in `config/settings.yaml`: `use_golden_image: false` (the server will pull architecture-native images directly via Docker on boot).
  2. Or update the Packer builder instance type in `iac/packer/` to an x86 model (e.g. `cx22`) before running `Build Golden Machine Image`.

---

## 🌐 DNS & Connection Issues

### ⚠️ Rapid Server Restarts: Cannot Connect via Domain Name

#### Symptom
After stopping and quickly restarting the server, connecting via your domain (e.g., `mc.example.com`) fails with `Unknown host`, `Connection refused`, or `Connection timed out`, even though the GitHub Actions `server-start.yml` workflow reports that the server is online and healthy.

#### Why This Happens
Hetzner Cloud VMs are ephemeral by default to minimize compute costs. Each time a server is provisioned, Hetzner assigns a **new dynamic public IPv4/IPv6 address**:

1. **Record Deletion on Shutdown**: When you stop the server (`server-stop.yml`), the DNS record is deleted from your DNS provider (IONOS or deSEC) so external clients do not hit a dead IP.
2. **The "Negative Caching" Trap (RFC 2308)**: If Minecraft, your operating system, or a home router polls the domain while the server is stopped (e.g. having the Minecraft Multiplayer server list open):
   - Your DNS provider returns `NXDOMAIN` or `NODATA` (record does not exist).
   - Upstream recursive resolvers (such as your ISP DNS or public resolvers like `1.1.1.1` and `8.8.8.8`) cache the **non-existence** of the record.
   - The negative cache duration is governed by your domain's **SOA `minimum` TTL**. For example, IONOS specifies a negative caching TTL of **600 seconds (10 minutes)**.
3. **Java Virtual Machine (JVM) Cache**: Minecraft runs on Java, which maintains its own internal DNS cache (`InetAddressCachePolicy`). Java caches negative lookups (`networkaddress.cache.negative.ttl`) and does not strictly decrement the packet's TTL, holding on to stale results.
4. **Home Router Clamping**: Many home routers (e.g., AVM FRITZ!Box, Asus, Netgear) run local DNS forwarders (`dnsmasq`/`unbound`) that clamp minimum TTLs to **300 seconds (5 minutes)** to reduce upstream query traffic.

Even after `server-start.yml` publishes the new IP with a 60-second TTL, intermediate resolvers holding the 10-minute negative cache will ignore the new record until their cache timer expires.

#### Solutions & Workarounds

##### Solution 1: Connect via Direct IP (Recommended for Rapid Restarts)
During rapid testing or successive restarts, bypass DNS entirely:
1. Open the **Job Summary** in GitHub Actions (under the completed `server-start.yml` run) or check the Discord bot start confirmation message.
2. Copy the raw IPv4 address (e.g., `142.132.x.x`).
3. In Minecraft, use **Direct Connection** (or edit the server entry) and paste the IP directly. Default port `25565` does not need to be typed.

##### Solution 2: Wait ~10 Minutes for Cache Eviction
If you prefer using your domain name, wait at least **10 minutes** after a restart before pinging the domain in your client to ensure the negative SOA cache expires across all intermediate resolvers.

##### Solution 3: Flush Local Caches
If only your local machine or client cached the stale lookup:
* **Minecraft / Java**: Restart the Minecraft client (this flushes Java's in-memory DNS cache).
* **Windows**:
  ```powershell
  ipconfig /flushdns
  ```
* **macOS**:
  ```bash
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
  ```
* **Linux** (`systemd-resolved`):
  ```bash
  resolvectl flush-caches
  ```

> [!NOTE]
> If your home router or ISP resolver cached the 10-minute negative response, flushing your local operating system DNS cache alone will not resolve the domain until the upstream router cache expires.

##### Solution 4: Static Primary IP on Hetzner (Permanent Architectural Fix)
If you want the domain name to work instantly across restarts without any DNS delay, assign a **Hetzner Cloud Primary IP** in your OpenTofu configuration (~€1.19/month for IPv4, free for IPv6). Because the server retains the exact same public IP across all destroy and recreate cycles, your DNS record never needs to change or be deleted.

---

## 🎮 Whitelist, Offline Mode & Player Authentication

### ⚠️ Unofficial / Non-Premium Minecraft Clients Cannot Connect

#### Symptom
Players connecting with offline or unofficial Minecraft launchers receive:
`Failed to verify username!` or `Disallowed by secure profile check`.

#### Solution
By default, the server enforces Mojang session authentication (`online_mode: true`) and Mojang-signed chat profiles (`enforce_secure_profile: true`). To allow non-premium or offline clients:

In `config/settings.yaml`:
```yaml
minecraft:
  online_mode: false
  enforce_secure_profile: false
```
Commit and push to `main`. When restarted, the server allows offline connections.

---

### ⚠️ Players "Not Found" or Rejected with Whitelist Enabled

#### Symptom
* Adding a player via `/whitelist add <PlayerName>` gives `Player does not exist` or `Player not found`.
* Alternatively, a valid player receives `You are not whitelisted on this server!` upon connecting.

#### Why This Happens
* **In Offline Mode (`online_mode: false`)**: The server cannot contact Mojang's central UUID lookup server. Instead, Minecraft generates offline UUIDs derived from the player's username hash. If the player has never connected to this specific server, their offline UUID does not exist in `usercache.json`, preventing `/whitelist add` from recognizing them.
* **Bedrock Players**: Bedrock players do not have Mojang UUIDs.

#### Solution: Temporary First-Join Workaround
1. Temporarily disable the whitelist in-game via a connected operator or the virtual console:
   ```text
   /whitelist off
   ```
2. Have the player connect to the server once. This registers their UUID in `usercache.json`.
3. Add them to the whitelist:
   * **Java Player**:
     ```text
     /whitelist add <ExactPlayerName>
     ```
   * **Bedrock Player**:
     ```text
     /whitelist add .<Gamertag>
     ```
     *(Or use `/fwhitelist add <Gamertag>` without disabling the whitelist).*
4. Re-enable the whitelist:
   ```text
   /whitelist on
   ```

---

## 🤖 Discord Bot Integration

### ⚠️ Discord Interactions Endpoint Verification Fails

#### Symptom
When configuring the **Interactions Endpoint URL** in the Discord Developer Portal, Discord shows an error: `The specified URL could not be verified`.

#### Solution
1. Ensure the Rust WebAssembly worker is successfully deployed and responds to POST requests:
   ```bash
   curl -i -X POST https://<worker-name>.<your-subdomain>.workers.dev
   ```
   *Expected output*: `HTTP/2 401` with body `Missing signature header`.
2. Check that the `DISCORD_PUBLIC_KEY` secret configured on the Cloudflare Worker matches the **Public Key** (64 hex characters) in the Discord Developer Portal (not the Application ID or Bot Token).
3. Inspect live logs using Wrangler while Discord tests verification:
   ```bash
   cd integrations/discord-bot
   npx wrangler tail
   ```
   This will display real-time diagnostic traces and any signature mismatch details.

For additional bot details, refer to the [Discord Bot Guide](../integrations/discord-bot/README.md).
