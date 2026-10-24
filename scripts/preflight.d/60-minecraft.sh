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
