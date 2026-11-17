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
  },
  {
    "name": "mc-players",
    "description": "List currently connected Minecraft players"
  },
  {
    "name": "mc-top",
    "description": "Show host CPU load, memory, world disk usage, uptime, and players"
  },
  {
    "name": "mc-whitelist",
    "description": "Manage the server whitelist",
    "options": [
      {
        "name": "add",
        "description": "Add a player to the whitelist",
        "type": 1,
        "options": [
          {
            "name": "player",
            "description": "Minecraft username (Java or Floodgate .Gamertag)",
            "type": 3,
            "required": true
          }
        ]
      },
      {
        "name": "remove",
        "description": "Remove a player from the whitelist",
        "type": 1,
        "options": [
          {
            "name": "player",
            "description": "Minecraft username to remove",
            "type": 3,
            "required": true
          }
        ]
      },
      {
        "name": "list",
        "description": "List all whitelisted players",
        "type": 1
      }
    ]
  },
  {
    "name": "mc-backup",
    "description": "Flush chunks (save-all flush) and save world state to disk"
  },
  {
    "name": "mc-restart",
    "description": "Gracefully stop the Minecraft JVM so Docker restarts it cleanly"
  },
  {
    "name": "mc-logs",
    "description": "Tail the latest server log lines (IP addresses redacted)",
    "options": [
      {
        "name": "lines",
        "description": "Number of log lines to display (1-80, default 40)",
        "type": 4,
        "required": false,
        "min_value": 1,
        "max_value": 80
      }
    ]
  },
  {
    "name": "mc-cmd",
    "description": "Execute a raw Minecraft server console command via RCON",
    "options": [
      {
        "name": "command",
        "description": "Server console command (without leading slash)",
        "type": 3,
        "required": true
      }
    ]
  },
  {
    "name": "mc-say",
    "description": "Send a chat message into Minecraft in-game chat",
    "options": [
      {
        "name": "message",
        "description": "Message to broadcast in-game",
        "type": 3,
        "required": true
      }
    ]
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
	echo "[✓] Successfully registered all 11 Discord slash commands."
else
	echo "[✗] Failed to register Discord slash commands (HTTP ${HTTP_STATUS}):" >&2
	echo "$BODY" >&2
	exit 1
fi
