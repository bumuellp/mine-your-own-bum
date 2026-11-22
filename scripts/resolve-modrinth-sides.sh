#!/usr/bin/env bash
# ==============================================================================
# Bulk Modrinth Project Side Resolver (Client-Required / Optional / Server-Only)
# Queries https://api.modrinth.com/v2/projects?ids=[...] in a single request,
# classifies configured minecraft.modrinth_projects by client_side, and resolves
# the effective Minecraft modloader (especially when server_type=MODRINTH).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

export SETTINGS_FILE="${SETTINGS_FILE:-${REPO_ROOT}/config/settings.yaml}"
[ -f "$SETTINGS_FILE" ] || export SETTINGS_FILE="${REPO_ROOT}/config/settings.example.yaml"

RAW_PROJECTS="$(get_setting_list "minecraft" "modrinth_projects" || echo "")"
MC_SERVER_TYPE="$(get_setting "minecraft" "server_type" || echo "FABRIC")"
MC_VERSION="$(get_setting "minecraft" "version" || echo "")"
MODRINTH_MODPACK="$(get_setting "minecraft" "modrinth_modpack" || echo "")"

CLIENT_REQUIRED=()
CLIENT_OPTIONAL=()
SERVER_ONLY=()

if [ -n "$RAW_PROJECTS" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	SLUGS_JSON="$(awk -F':' 'NF && $1 != "" { print $1 }' <<<"$RAW_PROJECTS" | jq -R . | jq -sc .)"
	TMP_RESP="$(mktemp)"
	HTTP_CODE="$(curl -s --max-time 5 -o "$TMP_RESP" -w "%{http_code}" \
		-H "User-Agent: mine-your-own-bum/1.0" \
		--get --data-urlencode "ids=${SLUGS_JSON}" \
		"https://api.modrinth.com/v2/projects" || echo "000")"

	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		slug="${entry%%:*}"
		side="required"
		if [ "$HTTP_CODE" = "200" ]; then
			side="$(jq -r --arg s "${slug,,}" '
				[.[] | select((.slug | ascii_downcase) == $s or (.id | ascii_downcase) == $s) | .client_side][0] // "required"
			' "$TMP_RESP" 2>/dev/null || echo "required")"
		fi
		case "$side" in
		unsupported)
			SERVER_ONLY+=("$entry")
			;;
		optional)
			CLIENT_OPTIONAL+=("$entry")
			;;
		*)
			CLIENT_REQUIRED+=("$entry")
			;;
		esac
	done <<<"$RAW_PROJECTS"
	rm -f "$TMP_RESP"
fi

MODLOADER="${MC_SERVER_TYPE,,}"
if [ -n "$MODRINTH_MODPACK" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
	MP_SLUG="${MODRINTH_MODPACK%%:*}"
	MP_SEL="release"
	if [[ "$MODRINTH_MODPACK" == *:* ]]; then
		MP_SEL="${MODRINTH_MODPACK#*:}"
	fi
	MP_SEL_LOWER="${MP_SEL,,}"

	TMP_MP="$(mktemp)"
	if [ -n "$MC_VERSION" ] && [ "${MC_VERSION^^}" != "LATEST" ] && [ "${MC_VERSION^^}" != "SNAPSHOT" ]; then
		MP_CODE="$(curl -s --max-time 5 -o "$TMP_MP" -w "%{http_code}" \
			-H "User-Agent: mine-your-own-bum/1.0" \
			--get --data-urlencode "game_versions=[\"${MC_VERSION}\"]" \
			"https://api.modrinth.com/v2/project/${MP_SLUG}/version" || echo "000")"
	else
		MP_CODE="$(curl -s --max-time 5 -o "$TMP_MP" -w "%{http_code}" \
			-H "User-Agent: mine-your-own-bum/1.0" \
			"https://api.modrinth.com/v2/project/${MP_SLUG}/version" || echo "000")"
	fi

	if [ "$MP_CODE" = "200" ]; then
		RESOLVED_LOADER="$(jq -r --arg sel "$MP_SEL" --arg sel_l "$MP_SEL_LOWER" '
			(
				if $sel_l == "release" then [.[] | select(.version_type == "release")]
				elif $sel_l == "beta" then [.[] | select(.version_type == "release" or .version_type == "beta")]
				elif $sel_l == "alpha" then .
				else [.[] | select(.version_number == $sel or .id == $sel)]
				end
			)[0].loaders[0] // empty
		' "$TMP_MP" 2>/dev/null || true)"
		if [ -n "$RESOLVED_LOADER" ]; then
			MODLOADER="${RESOLVED_LOADER,,}"
		fi
	fi
	rm -f "$TMP_MP"
fi

join_csv() {
	local IFS=","
	echo "$*"
}

REQ_CSV="$(join_csv "${CLIENT_REQUIRED[@]+"${CLIENT_REQUIRED[@]}"}")"
OPT_CSV="$(join_csv "${CLIENT_OPTIONAL[@]+"${CLIENT_OPTIONAL[@]}"}")"
SRV_CSV="$(join_csv "${SERVER_ONLY[@]+"${SERVER_ONLY[@]}"}")"

if [ "${1:-}" = "--github-output" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "client_required_mods=${REQ_CSV}"
		echo "client_optional_mods=${OPT_CSV}"
		echo "server_only_mods=${SRV_CSV}"
		echo "modloader=${MODLOADER}"
	} >>"$GITHUB_OUTPUT"
else
	echo "CLIENT_REQUIRED_MODS=${REQ_CSV}"
	echo "CLIENT_OPTIONAL_MODS=${OPT_CSV}"
	echo "SERVER_ONLY_MODS=${SRV_CSV}"
	echo "MC_MODLOADER=${MODLOADER}"
fi
