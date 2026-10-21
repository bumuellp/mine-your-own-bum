#!/usr/bin/env bash
# ==============================================================================
# Helper Script: Resolve Bedrock Gamertag to Floodgate UUID
# ==============================================================================
# Floodgate maps Bedrock players into Java Minecraft using deterministic UUIDs
# where the low 64 bits represent the player's numeric Xbox User ID (XUID).
#
# Usage:
#   ./scripts/get-bedrock-uuid.sh <gamertag>
#   ./scripts/get-bedrock-uuid.sh .<gamertag>
# ==============================================================================
set -euo pipefail

GAMERTAG="${1:-}"
if [ -z "$GAMERTAG" ]; then
	echo "Usage: $0 <bedrock_gamertag>"
	echo "Example: $0 GamerTag123"
	exit 1
fi

# Strip leading dot if provided (Floodgate prefix convention)
GAMERTAG="${GAMERTAG#.}"

echo "Resolving Bedrock Gamertag: '${GAMERTAG}'..."

if ! command -v jq >/dev/null 2>&1; then
	echo "Error: 'jq' is required but not installed." >&2
	exit 1
fi

RESP="$(curl -s -f "https://api.geysermc.org/v2/xbox/xuid/${GAMERTAG}" || true)"
if [ -z "$RESP" ]; then
	echo "Error: Could not resolve Gamertag '${GAMERTAG}'. Please verify Xbox Live spelling." >&2
	exit 1
fi

XUID="$(echo "$RESP" | jq -r '.xuid // empty')"
if [ -z "$XUID" ]; then
	echo "Error: No XUID returned for Gamertag '${GAMERTAG}'." >&2
	exit 1
fi

# Convert 64-bit integer XUID to 16-hex characters (lowercase)
HEX_XUID="$(printf "%016x" "$XUID")"
# Floodgate format: 00000000-0000-0000-xxxx-xxxxxxxxxxxx
UUID="00000000-0000-0000-${HEX_XUID:0:4}-${HEX_XUID:4:12}"

echo ""
echo "Gamertag:       ${GAMERTAG}"
echo "Xbox XUID:      ${XUID}"
echo "Floodgate UUID: ${UUID}"
echo ""
echo "Add to config/settings.yaml:"
echo "  whitelist:"
echo "    - \"${UUID}\"  # .${GAMERTAG} (Bedrock)"
