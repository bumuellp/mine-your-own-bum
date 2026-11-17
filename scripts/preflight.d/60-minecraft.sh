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
AUTH_PASS="$(get_secret "auth_password" || echo "")"
if [ -z "$AUTH_PASS" ]; then
	AUTH_PASS="$(get_setting "minecraft" "auth_password" || echo "")"
fi
AUTH_LOWER="$(echo "$AUTH_PASS" | tr '[:upper:]' '[:lower:]')"

if [ "$ONLINE_MODE" != "true" ] && [ "$ONLINE_MODE" != "false" ]; then
	echo -e "${RED}[✗] Minecraft Configuration:${NC} 'online_mode' must be set to 'true' or 'false' (found: '${ONLINE_MODE}')."
	ALL_OK=1
elif [ "$ONLINE_MODE" = "false" ]; then
	echo -e "${YELLOW}[!] Minecraft Security:${NC} 'online_mode' is disabled (offline/insecure mode). Mojang authentication bypassed."
else
	echo -e "${GREEN}[✓] Minecraft Security:${NC} 'online_mode' is enabled (Mojang authentication active)."
fi

if [ -n "$AUTH_PASS" ] && [ "$AUTH_LOWER" != "none" ]; then
	if [[ "$AUTH_PASS" == *"CHANGE_ME"* ]]; then
		echo -e "${RED}[✗] Minecraft In-Game Auth:${NC} 'auth_password' contains placeholder value in ${SECRETS_FILE}."
		ALL_OK=1
	else
		echo -e "${GREEN}[✓] Minecraft In-Game Auth:${NC} Enabled (in-game auth_password configured)."
	fi
else
	if [ "$ONLINE_MODE" = "false" ]; then
		echo -e "${YELLOW}[!] Minecraft In-Game Auth:${NC} Disabled ('auth_password' is empty or 'none') while online_mode is false."
	else
		echo -e "${BLUE}[i] Minecraft In-Game Auth:${NC} Disabled ('auth_password' is empty or 'none')."
	fi
fi

MODRINTH_MODPACK="$(get_setting "minecraft" "modrinth_modpack" || echo "")"
if [ -n "$MODRINTH_MODPACK" ]; then
	echo -e "${GREEN}[✓] Minecraft Modpack:${NC} Modrinth modpack '${MODRINTH_MODPACK}' configured."
fi

CF_PROJECTS="$(get_setting_list "minecraft" "curseforge_projects" || echo "")"
if [ -n "$CF_PROJECTS" ]; then
	CF_API_KEY_VAL="$(get_secret "cf_api_key" || echo "")"
	if [ -z "$CF_API_KEY_VAL" ] || [[ "$CF_API_KEY_VAL" == *"CHANGE_ME"* ]] || [[ "$CF_API_KEY_VAL" == *"YOUR_"* ]]; then
		echo -e "${RED}[✗] Minecraft CurseForge:${NC} 'cf_api_key' must be configured in ${SECRETS_FILE} when 'curseforge_projects' is non-empty."
		ALL_OK=1
	else
		echo -e "${GREEN}[✓] Minecraft CurseForge:${NC} CurseForge API key and project list validated."
	fi
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

if grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?(geyser|floodgate)["'"'"']?[[:space:]]*(#.*)?$' "$SETTINGS_FILE" >/dev/null 2>&1; then
	UNVERSIONED_MOD="$(grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?(geyser|floodgate)["'"'"']?[[:space:]]*(#.*)?$' "$SETTINGS_FILE" | head -n 1 | sed -E 's/^[[:space:]]*-[[:space:]]*["'"'"']?([^"'"'"'[:space:]#]+)["'"'"']?.*$/\1/')"
	echo -e "${RED}[✗] Minecraft Modrinth:${NC} Mod '${UNVERSIONED_MOD}' must specify a release channel or version (e.g. '${UNVERSIONED_MOD}:beta') because Geyser and Floodgate only publish 'beta' channel builds on Modrinth. Plain '${UNVERSIONED_MOD}' defaults to 'release' and will crash container startup."
	ALL_OK=1
else
	echo -e "${GREEN}[✓] Minecraft Modrinth:${NC} Dynamic mod definitions validated (channel/version specified for continuous builds)."
fi
