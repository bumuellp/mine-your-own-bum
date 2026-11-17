#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Sidecar Agent (mc-agent) & Cloudflare Tunnel
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

TUNNEL_TOKEN="$(get_secret "cloudflare_tunnel_token" || echo "")"
AGENT_SECRET="$(get_secret "agent_shared_secret" || echo "")"
CHAT_WEBHOOK="$(get_secret "discord_chat_webhook_url" || echo "")"
CMD_WEBHOOK="$(get_secret "discord_command_webhook_url" || echo "")"

is_placeholder() {
	local val="$1"
	[[ "$val" == *"CHANGE_ME"* ]] || [[ "$val" == *"YOUR_"* ]]
}

if [ -n "$TUNNEL_TOKEN" ]; then
	if is_placeholder "$TUNNEL_TOKEN"; then
		echo -e "${RED}[✗] Sidecar Tunnel:${NC} 'cloudflare_tunnel_token' contains placeholder value in ${SECRETS_FILE}."
		ALL_OK=1
	elif [ -z "$AGENT_SECRET" ] || is_placeholder "$AGENT_SECRET" || [ "${#AGENT_SECRET}" -lt 16 ]; then
		echo -e "${RED}[✗] Sidecar Agent:${NC} 'agent_shared_secret' (>= 16 chars) is required in ${SECRETS_FILE} when 'cloudflare_tunnel_token' is set."
		ALL_OK=1
	else
		echo -e "${GREEN}[✓] Sidecar Tunnel & Auth:${NC} Cloudflare tunnel token and agent_shared_secret configured."
	fi
else
	echo -e "${BLUE}[i] Sidecar Tunnel:${NC} Disabled (cloudflare_tunnel_token not set; mc-agent API tunnel skipped)."
fi

validate_webhook() {
	local label="$1"
	local url="$2"
	[ -z "$url" ] && return 0
	if is_placeholder "$url"; then
		echo -e "${RED}[✗] ${label}:${NC} Webhook URL contains placeholder value in ${SECRETS_FILE}."
		ALL_OK=1
	elif [[ "$url" =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/ ]]; then
		echo -e "${GREEN}[✓] ${label}:${NC} Discord webhook URL format valid."
	else
		echo -e "${RED}[✗] ${label}:${NC} Must start with 'https://discord.com/api/webhooks/'."
		ALL_OK=1
	fi
}

validate_webhook "Discord Chat Webhook" "$CHAT_WEBHOOK"
validate_webhook "Discord Command Webhook" "$CMD_WEBHOOK"
