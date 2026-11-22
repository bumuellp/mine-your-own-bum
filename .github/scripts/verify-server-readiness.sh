#!/usr/bin/env bash
# ==============================================================================
# Verify Minecraft Server Readiness & Healthcheck
# Performs a pure-Bash Minecraft Server List Ping (SLP) handshake on port 25565
# and requires two consecutive valid JSON status responses so a crashlooping
# JVM or half-open docker-proxy socket cannot produce a false positive.
# ==============================================================================
set -euo pipefail

SERVER_IP="${SERVER_IP:-}"
SERVER_PORT="${SERVER_PORT:-25565}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
RETRY_INTERVAL="${RETRY_INTERVAL:-6}"
REQUIRED_CONSECUTIVE="${REQUIRED_CONSECUTIVE:-2}"

if [ -z "$SERVER_IP" ]; then
	echo "::error ::SERVER_IP environment variable is required."
	exit 1
fi

probe_minecraft_slp() {
	local port_hi port_lo slp_bytes resp
	printf -v port_hi '%02x' "$((SERVER_PORT >> 8))"
	printf -v port_lo '%02x' "$((SERVER_PORT & 255))"

	# Minecraft SLP Handshake (packet len 8, id 0x00, proto 47, host "mc", port, next_state 1)
	# followed by Status Request (packet len 1, id 0x00).
	slp_bytes="\x08\x00\x2f\x02mc\x${port_hi}\x${port_lo}\x01\x01\x00"

	resp="$(printf '%b' "$slp_bytes" | timeout 4 nc -w 3 "$SERVER_IP" "$SERVER_PORT" 2>/dev/null | tr -cd '[:print:]' || true)"
	printf '%s' "$resp" | grep -qE '"(version|players|description)"'
}

echo "Waiting for Minecraft server on ${SERVER_IP}:${SERVER_PORT} to pass SLP readiness..."

ATTEMPT=0
CONSECUTIVE_OK=0
ONLINE=false

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
	if probe_minecraft_slp; then
		CONSECUTIVE_OK=$((CONSECUTIVE_OK + 1))
		echo "Minecraft SLP probe succeeded (${CONSECUTIVE_OK}/${REQUIRED_CONSECUTIVE}) at ${SERVER_IP}:${SERVER_PORT}."
		if [ "$CONSECUTIVE_OK" -ge "$REQUIRED_CONSECUTIVE" ]; then
			echo "::notice ::Minecraft server is ONLINE and answering SLP status pings at ${SERVER_IP}:${SERVER_PORT}!"
			ONLINE=true
			break
		fi
	else
		if [ "$CONSECUTIVE_OK" -gt 0 ]; then
			echo "WARNING: Minecraft SLP probe failed after partial pass (possible crashloop); resetting readiness counter."
		fi
		CONSECUTIVE_OK=0
		echo "Waiting for Minecraft engine to initialize... (attempt $((ATTEMPT + 1))/${MAX_ATTEMPTS})"
	fi
	sleep "$RETRY_INTERVAL"
	ATTEMPT=$((ATTEMPT + 1))
done

if [ "$ONLINE" != "true" ]; then
	echo "::error ::Minecraft server failed to answer ${REQUIRED_CONSECUTIVE} consecutive SLP pings on port ${SERVER_PORT} within timeout window."
	exit 1
fi
