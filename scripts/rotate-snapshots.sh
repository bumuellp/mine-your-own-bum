#!/usr/bin/env bash
# ==============================================================================
# Hetzner Cloud Snapshot Rotation Script
# Prunes older snapshot images matching a label selector to maintain a target count.
# ==============================================================================
set -euo pipefail

LABEL_SELECTOR="${1:-${LABEL_SELECTOR:-role=minecraft-golden-image}}"
KEEP_COUNT="${2:-${KEEP_COUNT:-1}}"

# Resolve Hetzner Cloud API token
if [ -z "${HCLOUD_TOKEN:-}" ]; then
	if [ -f "config/secrets.yaml" ]; then
		HCLOUD_TOKEN="$(grep -E '^hcloud_token:' config/secrets.yaml | head -n1 | awk '{print $2}' | tr -d '"'\''')"
	elif [ -f "config/secrets.enc.yaml" ] && command -v sops >/dev/null 2>&1; then
		HCLOUD_TOKEN="$(sops --decrypt --extract '["hcloud_token"]' config/secrets.enc.yaml 2>/dev/null || true)"
	fi
fi

if [ -z "${HCLOUD_TOKEN:-}" ] || [[ "${HCLOUD_TOKEN:-}" == *"YOUR_"* ]]; then
	echo "::error ::HCLOUD_TOKEN is not set or contains placeholder value." >&2
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "::error ::jq is required but not installed." >&2
	exit 1
fi

ENCODED_SELECTOR="$(printf '%s' "$LABEL_SELECTOR" | jq -sRr @uri)"
API_URL="https://api.hetzner.cloud/v1/images?type=snapshot&label_selector=${ENCODED_SELECTOR}&sort=created:desc"

echo "Querying Hetzner Cloud snapshots with label '${LABEL_SELECTOR}' (retaining newest ${KEEP_COUNT})..."

SNAPSHOTS_JSON="$(curl -fsSL -H "Authorization: Bearer ${HCLOUD_TOKEN}" "$API_URL")"
TOTAL_FOUND="$(echo "$SNAPSHOTS_JSON" | jq '.images | length')"

echo "Found ${TOTAL_FOUND} snapshot(s) matching '${LABEL_SELECTOR}'."

# Extract IDs of snapshots beyond KEEP_COUNT
OLD_SNAPSHOTS="$(echo "$SNAPSHOTS_JSON" | jq -c ".images[${KEEP_COUNT}:][]? // empty")"

if [ -z "$OLD_SNAPSHOTS" ]; then
	echo "No old snapshots to delete. Current count (${TOTAL_FOUND}) is within retention limit (${KEEP_COUNT})."
	exit 0
fi

echo "$OLD_SNAPSHOTS" | while IFS= read -r snapshot; do
	[ -n "$snapshot" ] || continue
	SNAPSHOT_ID="$(echo "$snapshot" | jq -r '.id')"
	SNAPSHOT_DESC="$(echo "$snapshot" | jq -r '.description // .name // "unnamed"')"
	SNAPSHOT_CREATED="$(echo "$snapshot" | jq -r '.created // "unknown"')"

	echo "Deleting old snapshot: ID=${SNAPSHOT_ID} (${SNAPSHOT_DESC}, created ${SNAPSHOT_CREATED})..."
	DELETE_RESP="$(curl -fsSL -w "%{http_code}" -o /dev/null -X DELETE \
		-H "Authorization: Bearer ${HCLOUD_TOKEN}" \
		"https://api.hetzner.cloud/v1/images/${SNAPSHOT_ID}")"

	if [ "$DELETE_RESP" -eq 204 ] || [ "$DELETE_RESP" -eq 200 ]; then
		echo "Successfully deleted snapshot ${SNAPSHOT_ID}."
	else
		echo "::warning ::Unexpected response (${DELETE_RESP}) while deleting snapshot ${SNAPSHOT_ID}."
	fi
done

echo "Snapshot rotation completed successfully. Retained newest ${KEEP_COUNT} snapshot(s)."
