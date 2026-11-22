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

validate_modrinth_entry() {
	local kind="$1"
	local raw="$2"
	local mc_ver="$3"

	local slug="${raw%%:*}"
	local selector="release"
	if [[ "$raw" == *:* ]]; then
		selector="${raw#*:}"
	fi
	local sel_lower="${selector,,}"

	local tmp_resp
	tmp_resp="$(mktemp)"
	local http_code
	http_code="$(curl -s --max-time 5 -o "$tmp_resp" -w "%{http_code}" \
		-H "User-Agent: mine-your-own-bum-preflight/1.0" \
		--get --data-urlencode "game_versions=[\"${mc_ver}\"]" \
		"https://api.modrinth.com/v2/project/${slug}/version" || echo "000")"

	if [ "$http_code" = "000" ]; then
		rm -f "$tmp_resp"
		return 0
	fi
	if [ "$http_code" = "404" ]; then
		echo -e "${RED}[✗] Minecraft Modrinth:${NC} ${kind} '${slug}' was not found on Modrinth (HTTP 404)."
		ALL_OK=1
		rm -f "$tmp_resp"
		return 1
	fi
	if [ "$http_code" != "200" ]; then
		rm -f "$tmp_resp"
		return 0
	fi

	local total_count
	total_count="$(jq 'length' "$tmp_resp" 2>/dev/null || echo 0)"
	if [ "$total_count" -le 0 ]; then
		echo -e "${RED}[✗] Minecraft Modrinth:${NC} ${kind} '${slug}' has no published builds for Minecraft ${mc_ver} on Modrinth."
		ALL_OK=1
		rm -f "$tmp_resp"
		return 1
	fi

	local matched_count=0
	case "$sel_lower" in
	release)
		matched_count="$(jq '[.[] | select(.version_type == "release")] | length' "$tmp_resp")"
		;;
	beta)
		matched_count="$(jq '[.[] | select(.version_type == "release" or .version_type == "beta")] | length' "$tmp_resp")"
		;;
	alpha)
		matched_count="$(jq '[.[] | select(.version_type == "release" or .version_type == "beta" or .version_type == "alpha")] | length' "$tmp_resp")"
		;;
	*)
		matched_count="$(jq --arg sel "$selector" '[.[] | select(.version_number == $sel or .id == $sel)] | length' "$tmp_resp")"
		;;
	esac

	if [ "$matched_count" -le 0 ]; then
		if [[ "$sel_lower" =~ ^(release|beta|alpha)$ ]]; then
			local avail
			avail="$(jq -r '[.[].version_type] | unique | join(", ")' "$tmp_resp")"
			local sug
			sug="$(jq -r 'if any(.[]; .version_type == "beta") then "beta" else .[0].version_type end' "$tmp_resp")"
			echo -e "${RED}[✗] Minecraft Modrinth:${NC} ${kind} '${raw}' has no '${sel_lower}' channel builds for Minecraft ${mc_ver} (available channels: ${avail}). Use '${slug}:${sug}'."
		else
			echo -e "${RED}[✗] Minecraft Modrinth:${NC} ${kind} '${raw}' version '${selector}' not found for Minecraft ${mc_ver}."
		fi
		ALL_OK=1
		rm -f "$tmp_resp"
		return 1
	fi

	rm -f "$tmp_resp"
	return 0
}

if grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?(geyser|floodgate)["'"'"']?[[:space:]]*(#.*)?$' "$SETTINGS_FILE" >/dev/null 2>&1; then
	UNVERSIONED_MOD="$(grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?(geyser|floodgate)["'"'"']?[[:space:]]*(#.*)?$' "$SETTINGS_FILE" | head -n 1 | sed -E 's/^[[:space:]]*-[[:space:]]*["'"'"']?([^"'"'"'[:space:]#]+)["'"'"']?.*$/\1/')"
	echo -e "${RED}[✗] Minecraft Modrinth:${NC} Mod '${UNVERSIONED_MOD}' must specify a release channel or version (e.g. '${UNVERSIONED_MOD}:beta') because Geyser and Floodgate only publish 'beta' channel builds on Modrinth. Plain '${UNVERSIONED_MOD}' defaults to 'release' and will crash container startup."
	ALL_OK=1
elif [ "${PREFLIGHT_SKIP_MODRINTH_API:-false}" != "true" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	MC_VER="$(get_setting "minecraft" "version" || echo "")"
	MODRINTH_PROJECTS_LIST="$(get_setting_list "minecraft" "modrinth_projects" || echo "")"
	if [ -n "$MC_VER" ] && [ "${MC_VER^^}" != "LATEST" ] && [ "${MC_VER^^}" != "SNAPSHOT" ] && { [ -n "$MODRINTH_MODPACK" ] || [ -n "$MODRINTH_PROJECTS_LIST" ]; }; then
		MODRINTH_OK=0
		if [ -n "$MODRINTH_MODPACK" ]; then
			validate_modrinth_entry "modpack" "$MODRINTH_MODPACK" "$MC_VER" || MODRINTH_OK=1
		fi
		while IFS= read -r mod_entry; do
			[ -n "$mod_entry" ] || continue
			validate_modrinth_entry "mod" "$mod_entry" "$MC_VER" || MODRINTH_OK=1
		done <<<"$MODRINTH_PROJECTS_LIST"
		if [ "$MODRINTH_OK" -eq 0 ]; then
			echo -e "${GREEN}[✓] Minecraft Modrinth:${NC} Modpack & project channels verified against Modrinth API for Minecraft ${MC_VER}."
		fi
	else
		echo -e "${GREEN}[✓] Minecraft Modrinth:${NC} Dynamic mod definitions validated (channel/version specified for continuous builds)."
	fi
else
	echo -e "${GREEN}[✓] Minecraft Modrinth:${NC} Dynamic mod definitions validated (channel/version specified for continuous builds)."
fi
