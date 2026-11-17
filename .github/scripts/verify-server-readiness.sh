#!/usr/bin/env bash
# ==============================================================================
# Verify Minecraft Server Readiness & Healthcheck
# Polls Minecraft TCP port 25565 until the server is reachable or timeout occurs.
# ==============================================================================
set -euo pipefail

SERVER_IP="${SERVER_IP:-}"
SERVER_PORT="${SERVER_PORT:-25565}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-50}"
RETRY_INTERVAL="${RETRY_INTERVAL:-6}"

if [ -z "$SERVER_IP" ]; then
	echo "::error ::SERVER_IP environment variable is required."
	exit 1
fi

echo "Waiting for Minecraft server on ${SERVER_IP}:${SERVER_PORT} to become reachable..."

ATTEMPT=0
ONLINE=false

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
	if nc -z -w 3 "$SERVER_IP" "$SERVER_PORT" 2>/dev/null; then
		echo "::notice ::Minecraft server is ONLINE and accepting connections at ${SERVER_IP}:${SERVER_PORT}!"
		ONLINE=true
		break
	fi
	echo "Waiting for Minecraft engine to initialize... (attempt $((ATTEMPT + 1))/${MAX_ATTEMPTS})"
	sleep "$RETRY_INTERVAL"
	ATTEMPT=$((ATTEMPT + 1))
done

if [ "$ONLINE" != "true" ]; then
	echo "::error ::Minecraft server failed to respond on port ${SERVER_PORT} within timeout window."
	exit 1
fi
