#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Dynamic DNS Provider API (IONOS / deSEC)
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

DNS_ENABLED="$(get_setting "dns" "enabled")"
DNS_PROVIDER="$(get_setting "dns" "provider")"
DNS_DOMAIN="$(get_setting "dns" "domain")"
DNS_TOKEN="$(get_secret "dns_token")"

if [ "$DNS_ENABLED" != "true" ]; then
	echo -e "${YELLOW}[i] DNS Synchronization:${NC} Disabled in ${SETTINGS_FILE} (skipping API check)."
elif [ -z "$DNS_TOKEN" ] || [[ "$DNS_TOKEN" == *"YOUR_"* ]]; then
	echo -e "${RED}[✗] DNS API:${NC} dns_token is missing or placeholder, but dns.enabled is set to true."
	ALL_OK=1
elif [ "$DNS_PROVIDER" = "ionos" ]; then
	if [[ "$DNS_TOKEN" != *.* ]]; then
		echo -e "${RED}[✗] IONOS DNS API:${NC} Invalid API key format!"
		echo "    IONOS keys must follow '<public_prefix>.<secret>' format separated by a dot ('.')."
		ALL_OK=1
	else
		RESP="$(curl -s -w "\n%{http_code}" \
			-H "X-API-Key: ${DNS_TOKEN}" \
			-H "Accept: application/json" \
			"https://api.hosting.ionos.com/dns/v1/zones")"
		HTTP_CODE="$(echo "$RESP" | tail -n 1)"
		BODY="$(echo "$RESP" | sed '$d')"
		if [ "$HTTP_CODE" -eq 200 ]; then
			if echo "$BODY" | grep -qi "\"name\":[[:space:]]*\"${DNS_DOMAIN}\""; then
				echo -e "${GREEN}[✓] IONOS DNS API:${NC} Token authenticated and zone '${DNS_DOMAIN}' found."
			else
				echo -e "${YELLOW}[!] IONOS DNS API:${NC} Token valid, but zone '${DNS_DOMAIN}' was not found in your account."
				ALL_OK=1
			fi
		else
			echo -e "${RED}[✗] IONOS DNS API:${NC} Authentication failed (HTTP ${HTTP_CODE}): ${BODY}"
			ALL_OK=1
		fi
	fi
elif [ "$DNS_PROVIDER" = "desec" ]; then
	RESP="$(curl -s -w "\n%{http_code}" \
		-H "Authorization: Token ${DNS_TOKEN}" \
		-H "Accept: application/json" \
		"https://desec.io/api/v1/domains/")"
	HTTP_CODE="$(echo "$RESP" | tail -n 1)"
	BODY="$(echo "$RESP" | sed '$d')"
	if [ "$HTTP_CODE" -eq 200 ]; then
		if echo "$BODY" | grep -qi "\"name\":[[:space:]]*\"${DNS_DOMAIN}\""; then
			echo -e "${GREEN}[✓] deSEC DNS API:${NC} Token authenticated and domain '${DNS_DOMAIN}' found."
		else
			echo -e "${YELLOW}[!] deSEC DNS API:${NC} Token valid, but domain '${DNS_DOMAIN}' was not found in your account."
			ALL_OK=1
		fi
	else
		echo -e "${RED}[✗] deSEC DNS API:${NC} Authentication failed (HTTP ${HTTP_CODE}): ${BODY}"
		ALL_OK=1
	fi
elif [ "$DNS_PROVIDER" = "hetzner" ]; then
	RESP="$(curl -s -w "\n%{http_code}" \
		-H "Authorization: Bearer ${DNS_TOKEN}" \
		-H "Accept: application/json" \
		"https://api.hetzner.cloud/v1/zones?name=${DNS_DOMAIN}")"
	HTTP_CODE="$(echo "$RESP" | tail -n 1)"
	BODY="$(echo "$RESP" | sed '$d')"
	if [ "$HTTP_CODE" -eq 200 ]; then
		if echo "$BODY" | grep -qi "\"name\":[[:space:]]*\"${DNS_DOMAIN}\""; then
			echo -e "${GREEN}[✓] Hetzner DNS API:${NC} Token authenticated and zone '${DNS_DOMAIN}' found."
		else
			echo -e "${YELLOW}[!] Hetzner DNS API:${NC} Token valid, but zone '${DNS_DOMAIN}' was not found in your account."
			ALL_OK=1
		fi
	else
		echo -e "${RED}[✗] Hetzner DNS API:${NC} Authentication failed (HTTP ${HTTP_CODE}): ${BODY}"
		ALL_OK=1
	fi
else
	echo -e "${YELLOW}[!] DNS Provider:${NC} '${DNS_PROVIDER}' is not pre-validated (supported: 'desec', 'ionos', 'hetzner')."
fi
