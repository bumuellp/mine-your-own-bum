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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

export SETTINGS_FILE="${REPO_ROOT}/config/settings.yaml"
[ -f "$SETTINGS_FILE" ] || export SETTINGS_FILE="${REPO_ROOT}/config/settings.example.yaml"

MC_SERVER_TYPE="$(get_setting "minecraft" "server_type" || echo "FABRIC")"
MC_VERSION="$(get_setting "minecraft" "version" || echo "LATEST")"
MC_MODPACK="$(get_setting "minecraft" "modrinth_modpack" || echo "")"
MC_MODRINTH_LIST="$(get_setting_list "minecraft" "modrinth_projects" || echo "")"
MC_CF_LIST="$(get_setting_list "minecraft" "curseforge_projects" || echo "")"

HAS_GEYSER="false"
if echo "$MC_MODRINTH_LIST" | grep -qiE '^geyser(:|$)'; then
	HAS_GEYSER="true"
fi

TABLE_ROWS=(
	"| **Domain / FQDN** | \`${DISPLAY_DOMAIN}\` |"
	"| **Java Edition** | \`${JAVA_HOST}:25565\` |"
)
if [ "$HAS_GEYSER" = "true" ]; then
	TABLE_ROWS+=("| **Bedrock Edition** | \`${BEDROCK_HOST}:19132\` (Port: \`19132\`) |")
fi
TABLE_ROWS+=("| **Server Loader & Version** | \`${MC_SERVER_TYPE}\` (Minecraft \`${MC_VERSION}\`) |")
if [ -n "$SERVER_TYPE_VAL" ]; then
	TABLE_ROWS+=("| **Server Model** | \`${SERVER_TYPE_VAL}\` (\`${SERVER_ARCH_VAL}\`) |")
fi
TABLE_ROWS+=("| **IPv4 Address** | \`${IPV4}\` |")
if [ -n "$IPV6" ]; then
	TABLE_ROWS+=("| **IPv6 Address** | \`${IPV6}\` |")
fi
CONNECTION_TABLE="$(printf '%s\n' "${TABLE_ROWS[@]}")"

CLIENT_REQ_CSV=""
CLIENT_OPT_CSV=""
SERVER_ONLY_CSV=""
while IFS='=' read -r k v; do
	case "$k" in
	CLIENT_REQUIRED_MODS) CLIENT_REQ_CSV="$v" ;;
	CLIENT_OPTIONAL_MODS) CLIENT_OPT_CSV="$v" ;;
	SERVER_ONLY_MODS) SERVER_ONLY_CSV="$v" ;;
	esac
done < <(SETTINGS_FILE="$SETTINGS_FILE" "${REPO_ROOT}/scripts/resolve-modrinth-sides.sh")

CLIENT_MOD_LINES=()
if [ -n "$MC_MODPACK" ]; then
	MP_SLUG="${MC_MODPACK%%:*}"
	CLIENT_MOD_LINES+=("- **Base Modpack (Modrinth — Required)**: [${MP_SLUG}](https://modrinth.com/modpack/${MP_SLUG}) (\`${MC_MODPACK}\`)")
fi

IFS=',' read -r -a REQ_ARR <<<"$CLIENT_REQ_CSV"
for mod_entry in "${REQ_ARR[@]}"; do
	[ -n "$mod_entry" ] || continue
	MOD_SLUG="${mod_entry%%:*}"
	CLIENT_MOD_LINES+=("- **Required Mod (Modrinth)**: [${MOD_SLUG}](https://modrinth.com/mod/${MOD_SLUG}) (\`${mod_entry}\`)")
done

while IFS= read -r cf_entry; do
	[ -n "$cf_entry" ] || continue
	CF_SLUG="${cf_entry%%:*}"
	CLIENT_MOD_LINES+=("- **Required Mod (CurseForge)**: [${CF_SLUG}](https://www.curseforge.com/minecraft/mc-mods/${CF_SLUG}) (\`${cf_entry}\`)")
done <<<"$MC_CF_LIST"

if [ "${#CLIENT_MOD_LINES[@]}" -eq 0 ]; then
	CLIENT_MOD_LINES+=("- ✅ **No client mods required to join!** Standard Vanilla clients can connect directly.")
fi

IFS=',' read -r -a OPT_ARR <<<"$CLIENT_OPT_CSV"
for opt_entry in "${OPT_ARR[@]}"; do
	[ -n "$opt_entry" ] || continue
	OPT_SLUG="${opt_entry%%:*}"
	CLIENT_MOD_LINES+=("- *Optional on Client (Modrinth)*: [${OPT_SLUG}](https://modrinth.com/mod/${OPT_SLUG}) (\`${opt_entry}\`)")
done

IFS=',' read -r -a SRV_ARR <<<"$SERVER_ONLY_CSV"
for srv_entry in "${SRV_ARR[@]}"; do
	[ -n "$srv_entry" ] || continue
	SRV_SLUG="${srv_entry%%:*}"
	CLIENT_MOD_LINES+=("- *Server-Only (No Client Install Needed)*: [${SRV_SLUG}](https://modrinth.com/mod/${SRV_SLUG}) (\`${srv_entry}\`)")
done

CLIENT_MODS_SECTION="$(printf '%s\n' "${CLIENT_MOD_LINES[@]}")"

cat <<EOF >>"$SUMMARY_FILE"
## 🎮 Minecraft Server Status: **ONLINE**

${BOOT_STATUS}

### 🌐 Connection Information
| Parameter | Value |
| :--- | :--- |
${CONNECTION_TABLE}

### 📦 Client Setup & Required Mods
${CLIENT_MODS_SECTION}

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
