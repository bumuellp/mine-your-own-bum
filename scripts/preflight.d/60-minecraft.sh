#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Minecraft Access Control & Whitelist
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

ONLINE_MODE="$(get_setting "minecraft" "online_mode")"
if [ "$ONLINE_MODE" != "true" ] && [ "$ONLINE_MODE" != "false" ]; then
	echo -e "${RED}[✗] Minecraft Configuration:${NC} 'online_mode' must be set to 'true' or 'false' (found: '${ONLINE_MODE}')."
	ALL_OK=1
elif [ "$ONLINE_MODE" = "false" ]; then
	echo -e "${YELLOW}[!] Minecraft Security:${NC} 'online_mode' is disabled (offline/insecure mode). Mojang authentication bypassed."
else
	echo -e "${GREEN}[✓] Minecraft Security:${NC} 'online_mode' is enabled (Mojang authentication active)."
fi

ENFORCE_SECURE="$(get_setting "minecraft" "enforce_secure_profile")"
if [ "$ENFORCE_SECURE" != "true" ] && [ "$ENFORCE_SECURE" != "false" ]; then
	echo -e "${RED}[✗] Minecraft Configuration:${NC} 'enforce_secure_profile' must be set to 'true' or 'false' (found: '${ENFORCE_SECURE}')."
	ALL_OK=1
fi

WL_ENABLED="$(get_setting "minecraft" "whitelist_enabled" || echo "false")"
if [ "$WL_ENABLED" = "true" ]; then
	if grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?\.[a-zA-Z0-9_]' "$SETTINGS_FILE" >/dev/null 2>&1; then
		BAD_NAME="$(grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?\.[a-zA-Z0-9_]' "$SETTINGS_FILE" | head -n 1 | sed -E 's/^[[:space:]]*-[[:space:]]*["'"'"']?([^"'"'"'[:space:]]+)["'"'"']?.*$/\1/')"
		echo -e "${RED}[✗] Minecraft Whitelist:${NC} Bedrock username '${BAD_NAME}' detected. Bedrock players must use their Floodgate UUID (format: 00000000-0000-0000-xxxx-xxxxxxxxxxxx) because Mojang API cannot resolve Bedrock gamertags."
		ALL_OK=1
	else
		echo -e "${GREEN}[✓] Minecraft Whitelist:${NC} Access control whitelist is enabled."
	fi
fi
