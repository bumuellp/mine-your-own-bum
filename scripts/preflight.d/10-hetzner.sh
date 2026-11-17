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

		SERVER_TYPE="${TF_VAR_server_type:-$(get_setting "server" "server_type" || echo "")}"
		if [ -z "$SERVER_TYPE" ]; then
			echo -e "${RED}[✗] Hetzner Server Sizing:${NC} 'server.server_type' is missing in ${SETTINGS_FILE}."
			ALL_OK=1
			SERVER_TYPE="cax21"
		fi
		LOCATION="$(get_setting "server" "location" || echo "fsn1")"
		[ -n "$LOCATION" ] || LOCATION="fsn1"
		USE_GOLDEN="$(get_setting "server" "use_golden_image" || echo "false")"

		# Parse fallback server types from settings.yaml
		FALLBACK_TYPES="$(get_setting_list "server" "fallback_server_types")"

		if command -v jq >/dev/null 2>&1; then
			CANDIDATES=("$SERVER_TYPE")
			while IFS= read -r fb; do
				[ -n "$fb" ] || continue
				[ "$fb" != "$SERVER_TYPE" ] || continue
				CANDIDATES+=("$fb")
			done <<<"$FALLBACK_TYPES"

			CHOSEN_TYPE=""
			CHOSEN_ARCH=""

			for candidate in "${CANDIDATES[@]}"; do
				AVAIL="false"
				TYPE_RESP=""
				for attempt in 1 2; do
					TYPE_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/server_types?name=${candidate}")"
					AVAIL="$(echo "$TYPE_RESP" | jq -r --arg loc "$LOCATION" '[.server_types[0].locations[]? | select(.name == $loc) | .available][0]')"
					if [ "$AVAIL" = "true" ]; then
						break
					fi
					[ "$attempt" -lt 2 ] && sleep 2
				done

				[ "$AVAIL" = "true" ] || continue

				CAND_ARCH="$(echo "$TYPE_RESP" | jq -r '.server_types[0].architecture // empty')"

				# If golden image is enabled, verify a snapshot exists for this architecture before selecting
				if [ "$USE_GOLDEN" = "true" ]; then
					ARCH_QUERY=""
					[ -n "$CAND_ARCH" ] && ARCH_QUERY="&architecture=${CAND_ARCH}"
					HCLOUD_IMAGES_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=role%3Dminecraft-golden-image${ARCH_QUERY}")"
					GOLDEN_COUNT="$(echo "$HCLOUD_IMAGES_RESP" | jq '.images | length' 2>/dev/null || echo 0)"
					if [ "$GOLDEN_COUNT" -le 0 ]; then
						echo -e "${YELLOW}[!] Hetzner Server Sizing:${NC} Candidate '${candidate}' (${CAND_ARCH}) is available in '${LOCATION}', but no snapshot with 'role=minecraft-golden-image' (${CAND_ARCH}) exists. Skipping..."
						continue
					fi
				fi

				CHOSEN_TYPE="$candidate"
				CHOSEN_ARCH="$CAND_ARCH"
				break
			done

			# Graceful fallback to docker-ce if golden image is missing for all available candidates
			CHOSEN_IMAGE=""
			if [ -z "$CHOSEN_TYPE" ] && [ "$USE_GOLDEN" = "true" ]; then
				for candidate in "${CANDIDATES[@]}"; do
					TYPE_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/server_types?name=${candidate}")"
					AVAIL="$(echo "$TYPE_RESP" | jq -r --arg loc "$LOCATION" '[.server_types[0].locations[]? | select(.name == $loc) | .available][0]')"
					if [ "$AVAIL" = "true" ]; then
						CHOSEN_TYPE="$candidate"
						CHOSEN_ARCH="$(echo "$TYPE_RESP" | jq -r '.server_types[0].architecture // empty')"
						CHOSEN_IMAGE="docker-ce"
						break
					fi
				done
			fi

			if [ -n "$CHOSEN_TYPE" ]; then
				if [ "$CHOSEN_TYPE" = "$SERVER_TYPE" ]; then
					echo -e "${GREEN}[✓] Hetzner Server Sizing:${NC} Primary model '${CHOSEN_TYPE}' (${CHOSEN_ARCH}) is available in '${LOCATION}'."
				else
					echo -e "${YELLOW}[!] Hetzner Server Sizing:${NC} Primary model '${SERVER_TYPE}' was unavailable. Waterfall fallback selected '${CHOSEN_TYPE}' (${CHOSEN_ARCH}) in '${LOCATION}'."
				fi

				if [ "$CHOSEN_IMAGE" = "docker-ce" ]; then
					echo -e "${BLUE}[i] Hetzner Golden Image:${NC} No active snapshot found. Gracefully falling back to base 'docker-ce' image (containers will pull on boot)."
				elif [ "$USE_GOLDEN" = "true" ]; then
					echo -e "${GREEN}[✓] Hetzner Golden Image:${NC} Active snapshot with 'role=minecraft-golden-image' (${CHOSEN_ARCH}) verified."
				fi

				if [ -n "${GITHUB_ENV:-}" ]; then
					echo "TF_VAR_server_type=${CHOSEN_TYPE}" >>"$GITHUB_ENV"
				fi
			else
				echo -e "${RED}[✗] Hetzner Server Sizing:${NC} Primary model '${SERVER_TYPE}' and fallbacks (${CANDIDATES[*]}) are unavailable in '${LOCATION}'."
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
		fi
	else
		echo -e "${RED}[✗] Hetzner Cloud API:${NC} Authentication failed (HTTP ${HTTP_CODE}). Check hcloud_token."
		ALL_OK=1
	fi
fi
