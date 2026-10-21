#!/usr/bin/env bash
# ==============================================================================
# Graceful Server ACPI Shutdown for Mine Your Own Bum
# Sends an ACPI shutdown event to Hetzner Cloud to allow systemd and Docker
# to flush Minecraft world chunks and unmount persistent storage cleanly
# before targeted OpenTofu destruction.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SERVER_ID="${SERVER_ID:-}"
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"

# Parse token from decrypted secrets if not explicitly provided in environment
if [ -z "$HCLOUD_TOKEN" ]; then
	SECRETS_FILE="${REPO_ROOT}/config/secrets.yaml"
	if [ -f "$SECRETS_FILE" ]; then
		HCLOUD_TOKEN="$(grep "^hcloud_token:" "$SECRETS_FILE" | cut -d'"' -f2 || true)"
	fi
fi

if [ -z "$SERVER_ID" ]; then
	echo "No active server ID detected. Skipping ACPI shutdown."
	exit 0
fi

if [ -z "$HCLOUD_TOKEN" ]; then
	echo "WARNING: HCLOUD_TOKEN not available. Skipping ACPI shutdown."
	exit 0
fi

echo "Checking status of Hetzner server ${SERVER_ID}..."
RESP="$(curl -s -w "\n%{http_code}" \
	-H "Authorization: Bearer ${HCLOUD_TOKEN}" \
	-H "Accept: application/json" \
	"https://api.hetzner.cloud/v1/servers/${SERVER_ID}")"

HTTP_CODE="$(echo "$RESP" | tail -n 1)"
BODY="$(echo "$RESP" | sed '$d')"

if [ "$HTTP_CODE" -ne 200 ]; then
	echo "Server ${SERVER_ID} not found or Hetzner API returned HTTP ${HTTP_CODE}. Proceeding to destroy."
	exit 0
fi

SERVER_STATUS="$(echo "$BODY" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

if [ "$SERVER_STATUS" != "running" ]; then
	echo "Server ${SERVER_ID} is currently '${SERVER_STATUS:-off}'. Proceeding directly to OpenTofu destroy."
	exit 0
fi

echo "Server ${SERVER_ID} is running. Dispatching ACPI shutdown event to flush world chunks..."
SHUTDOWN_RESP="$(curl -s -w "\n%{http_code}" -X POST \
	-H "Authorization: Bearer ${HCLOUD_TOKEN}" \
	-H "Content-Type: application/json" \
	"https://api.hetzner.cloud/v1/servers/${SERVER_ID}/actions/shutdown")"

SHUTDOWN_CODE="$(echo "$SHUTDOWN_RESP" | tail -n 1)"
if [ "$SHUTDOWN_CODE" -ne 201 ]; then
	echo "WARNING: Failed to initiate ACPI shutdown (HTTP ${SHUTDOWN_CODE}). Proceeding to destroy."
	exit 0
fi

echo "Awaiting graceful shutdown and disk flush (up to 30 seconds)..."
for i in $(seq 1 10); do
	sleep 3
	CHECK_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/servers/${SERVER_ID}" || true)"
	CUR_STATUS="$(echo "$CHECK_RESP" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	if [ "$CUR_STATUS" = "off" ]; then
		echo "[✓] Server ${SERVER_ID} shut down cleanly. Storage unmounted and chunks flushed."
		exit 0
	fi
	echo "    Waiting for server shutdown (status: '${CUR_STATUS:-unknown}', $((i * 3))/30s)..."
done

echo "ACPI shutdown wait window completed. Proceeding to OpenTofu destroy."
