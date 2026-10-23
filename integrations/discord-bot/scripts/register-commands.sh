#!/usr/bin/env bash
# ==============================================================================
# Register Discord Slash Commands via Discord REST API
# ==============================================================================
# Usage:
#   DISCORD_BOT_TOKEN="xxx" DISCORD_APPLICATION_ID="yyy" ./scripts/register-commands.sh
#
# Optional:
#   GUILD_ID="zzz" ./scripts/register-commands.sh  (Registers immediately to specific server)
# ==============================================================================
set -euo pipefail

BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
APP_ID="${DISCORD_APPLICATION_ID:-}"
GUILD_ID="${GUILD_ID:-}"

if [ -z "$BOT_TOKEN" ] || [ -z "$APP_ID" ]; then
	echo "Error: DISCORD_BOT_TOKEN and DISCORD_APPLICATION_ID environment variables are required." >&2
	echo "Usage: DISCORD_BOT_TOKEN=\"...\" DISCORD_APPLICATION_ID=\"...\" $0" >&2
	exit 1
fi

COMMANDS_JSON='[
  {
    "name": "mc-start",
    "description": "Provision and start the on-demand Minecraft server"
  },
  {
    "name": "mc-stop",
    "description": "Gracefully flush chunks, backup world, and shut down server"
  },
  {
    "name": "mc-status",
    "description": "Check if the server is running or if a workflow is in progress"
  }
]'

if [ -n "$GUILD_ID" ]; then
	API_URL="https://discord.com/api/v10/applications/${APP_ID}/guilds/${GUILD_ID}/commands"
	echo "Registering slash commands specifically to Guild '${GUILD_ID}' (Instant)..."
else
	API_URL="https://discord.com/api/v10/applications/${APP_ID}/commands"
	echo "Registering slash commands globally (May take up to 10 minutes to propagate)..."
fi

HTTP_RESPONSE="$(curl -s -w "\n%{http_code}" -X PUT \
	-H "Authorization: Bot ${BOT_TOKEN}" \
	-H "Content-Type: application/json" \
	-d "$COMMANDS_JSON" \
	"$API_URL")"

HTTP_STATUS="$(echo "$HTTP_RESPONSE" | tail -n 1)"
BODY="$(echo "$HTTP_RESPONSE" | sed '$d')"

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
	echo "[✓] Successfully registered Discord slash commands: /mc-start, /mc-stop, /mc-status"
else
	echo "[✗] Failed to register Discord slash commands (HTTP ${HTTP_STATUS}):" >&2
	echo "$BODY" >&2
	exit 1
fi
