#!/usr/bin/env bash
# ==============================================================================
# Bulk Modrinth Project Side Resolver (Client-Required / Optional / Server-Only)
# Queries https://api.modrinth.com/v2/projects?ids=[...] in a single request
# and classifies configured minecraft.modrinth_projects by client_side.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

export SETTINGS_FILE="${SETTINGS_FILE:-${REPO_ROOT}/config/settings.yaml}"
[ -f "$SETTINGS_FILE" ] || export SETTINGS_FILE="${REPO_ROOT}/config/settings.example.yaml"

RAW_PROJECTS="$(get_setting_list "minecraft" "modrinth_projects" || echo "")"

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
	} >>"$GITHUB_OUTPUT"
else
	echo "CLIENT_REQUIRED_MODS=${REQ_CSV}"
	echo "CLIENT_OPTIONAL_MODS=${OPT_CSV}"
	echo "SERVER_ONLY_MODS=${SRV_CSV}"
fi
