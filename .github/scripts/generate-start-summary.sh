#!/usr/bin/env bash
# ==============================================================================
# Generate GitHub Actions Step Summary for Server Start
# Formats markdown status table and outputs to $GITHUB_STEP_SUMMARY.
# ==============================================================================
set -euo pipefail

IPV4="${IPV4:-}"
IPV6="${IPV6:-}"
DNS_ENABLED="${DNS_ENABLED:-false}"
FQDN="${FQDN:-}"
ALREADY_RUNNING="${ALREADY_RUNNING:-false}"
SERVER_TYPE_VAL="${SERVER_TYPE_VAL:-}"
SERVER_ARCH_VAL="${SERVER_ARCH_VAL:-}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

BOOT_STATUS="The ephemeral cloud server has been provisioned and persistent storage attached."
if [ "$ALREADY_RUNNING" = "true" ]; then
	BOOT_STATUS="The server instance was already running in remote state; configuration is unchanged."
fi

if [ "$DNS_ENABLED" = "true" ] && [ -n "$FQDN" ]; then
	JAVA_HOST="$FQDN"
	BEDROCK_HOST="$FQDN"
	DISPLAY_DOMAIN="$FQDN"
else
	JAVA_HOST="$IPV4"
	BEDROCK_HOST="$IPV4"
	DISPLAY_DOMAIN="*Not configured (using raw IP)*"
fi

SERVER_ROW=""
if [ -n "$SERVER_TYPE_VAL" ]; then
	SERVER_ROW="| **Server Model** | \`${SERVER_TYPE_VAL}\` (\`${SERVER_ARCH_VAL}\`) |"
fi

IPV6_ROW=""
if [ -n "$IPV6" ]; then
	IPV6_ROW="| **IPv6 Address** | \`${IPV6}\` |"
fi

cat <<EOF >>"$SUMMARY_FILE"
## 🎮 Minecraft Server Status: **ONLINE**

${BOOT_STATUS}

### 🌐 Connection Information
| Parameter | Value |
| :--- | :--- |
| **Domain / FQDN** | \`${DISPLAY_DOMAIN}\` |
| **Java Edition** | \`${JAVA_HOST}:25565\` |
| **Bedrock Edition** | \`${BEDROCK_HOST}:19132\` (Port: \`19132\`) |
${SERVER_ROW}
| **IPv4 Address** | \`${IPV4}\` |
${IPV6_ROW}

> [!NOTE]
> Because compute instances are completely ephemeral, **every boot is a fresh boot**.
> Docker and Minecraft containers initialize and verify runtime files upon startup.
> It may take **1 to 2 minutes** before the server begins answering player pings on port 25565 / 19132.

### 🛑 Shutdown & Idle Watchdog
- **Automatic Idle Stop**: If no players are online for the configured idle threshold,
  the server automatically saves world data and terminates the VM to prevent cloud costs.
- **Manual Stop**: Run the **Stop Minecraft Server** workflow whenever you finish playing.
- **Data Retention**: World saves, player data, and configurations are permanently stored
  on the persistent Hetzner volume and survive VM destruction.
EOF
