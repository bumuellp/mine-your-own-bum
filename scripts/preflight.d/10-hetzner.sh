#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Hetzner Cloud API, Server Sizing & SSH Keys
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

HCLOUD_TOKEN="$(get_secret "hcloud_token")"
if [ -z "$HCLOUD_TOKEN" ] || [[ "$HCLOUD_TOKEN" == *"YOUR_"* ]]; then
	echo -e "${RED}[✗] Hetzner Cloud API:${NC} Missing or placeholder value in ${SECRETS_FILE}."
	ALL_OK=1
else
	HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
		-H "Authorization: Bearer ${HCLOUD_TOKEN}" \
		"https://api.hetzner.cloud/v1/servers")"
	if [ "$HTTP_CODE" -eq 200 ]; then
		echo -e "${GREEN}[✓] Hetzner Cloud API:${NC} Token authenticated successfully (HTTP 200)."

		SERVER_TYPE="$(get_setting "server" "server_type" || echo "cax21")"
		LOCATION="$(get_setting "server" "location" || echo "fsn1")"
		if command -v jq >/dev/null 2>&1; then
			TYPE_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/server_types?name=${SERVER_TYPE}")"
			AVAIL="$(echo "$TYPE_RESP" | jq -r --arg loc "$LOCATION" '[.server_types[0].locations[]? | select(.name == $loc) | .available][0]')"
			if [ "$AVAIL" = "true" ]; then
				echo -e "${GREEN}[✓] Hetzner Server Sizing:${NC} Model '${SERVER_TYPE}' is available in '${LOCATION}'."
			elif [ "$AVAIL" = "false" ]; then
				echo -e "${RED}[✗] Hetzner Server Sizing:${NC} Server Type '${SERVER_TYPE}' is unavailable in '${LOCATION}'."
				ALL_OK=1
			fi

			# Validate Hetzner SSH keys
			SSH_KEYS="$(get_setting_list "server" "ssh_keys")"
			if [ -z "$SSH_KEYS" ]; then
				echo -e "${RED}[✗] Hetzner SSH Keys:${NC} 'server.ssh_keys' is empty in ${SETTINGS_FILE}. At least one SSH key is required."
				ALL_OK=1
			else
				HCLOUD_KEYS_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/ssh_keys")"
				while IFS= read -r key_entry; do
					[ -n "$key_entry" ] || continue
					if echo "$HCLOUD_KEYS_RESP" | jq -e --arg k "$key_entry" '.ssh_keys[] | select(.name == $k or (.id|tostring) == $k)' >/dev/null 2>&1; then
						echo -e "${GREEN}[✓] Hetzner SSH Key:${NC} Key '${key_entry}' verified in Hetzner project (suppresses password emails)."
					else
						echo -e "${RED}[✗] Hetzner SSH Key:${NC} Key '${key_entry}' was not found in your Hetzner Cloud project."
						ALL_OK=1
					fi
				done <<<"$SSH_KEYS"
			fi

			# Validate Golden Image snapshot if enabled
			USE_GOLDEN="$(get_setting "server" "use_golden_image" || echo "false")"
			if [ "$USE_GOLDEN" = "true" ]; then
				HCLOUD_IMAGES_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=role%3Dminecraft-golden-image")"
				GOLDEN_COUNT="$(echo "$HCLOUD_IMAGES_RESP" | jq '.images | length' 2>/dev/null || echo 0)"
				if [ "$GOLDEN_COUNT" -gt 0 ]; then
					echo -e "${GREEN}[✓] Hetzner Golden Image:${NC} Active snapshot with 'role=minecraft-golden-image' verified."
				else
					echo -e "${RED}[✗] Hetzner Golden Image:${NC} server.use_golden_image is true, but no snapshot with 'role=minecraft-golden-image' was found in your Hetzner Cloud project."
					ALL_OK=1
				fi
			fi
		fi
	else
		echo -e "${RED}[✗] Hetzner Cloud API:${NC} Authentication failed (HTTP ${HTTP_CODE}). Check hcloud_token."
		ALL_OK=1
	fi
fi
