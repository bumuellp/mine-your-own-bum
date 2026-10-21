#!/usr/bin/env bash
# ==============================================================================
# Container Smoke Test for Mine Your Own Bum
# Renders the compose template, validates syntax, boots the test container,
# and verifies engine readiness and RCON communication.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
MOUNT_DIR="/mnt/mc-data"

cleanup() {
	echo "==> Cleaning up smoke test resources..."
	if [ -f "$COMPOSE_FILE" ]; then
		docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
		rm -f "$COMPOSE_FILE"
	fi
	if [ -d "$MOUNT_DIR" ]; then
		sudo rm -rf "$MOUNT_DIR" 2>/dev/null || rm -rf "$MOUNT_DIR" 2>/dev/null || true
	fi
	rm -rf "${REPO_ROOT}/tests/smoke-test/.terraform"* "${REPO_ROOT}/tests/smoke-test/terraform.tfstate"* >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "==> Step 1: Rendering Docker Compose specification via OpenTofu..."
tofu -chdir=tests/smoke-test init -input=false >/dev/null
tofu -chdir=tests/smoke-test apply -auto-approve -input=false >/dev/null
tofu -chdir=tests/smoke-test output -raw docker_compose >"$COMPOSE_FILE"

echo "==> Step 2: Validating Docker Compose syntax..."
docker compose -f "$COMPOSE_FILE" config >/dev/null
echo "[✓] Docker Compose syntax valid."

echo "==> Step 3: Preparing persistent mount directory..."
if command -v sudo >/dev/null 2>&1; then
	sudo mkdir -p "$MOUNT_DIR"
	sudo chmod 777 "$MOUNT_DIR"
else
	mkdir -p "$MOUNT_DIR"
	chmod 777 "$MOUNT_DIR"
fi

echo "==> Step 4: Launching Minecraft test container..."
docker compose -f "$COMPOSE_FILE" up -d mc-server

echo "==> Step 5: Awaiting engine initialization and healthcheck..."
MAX_ATTEMPTS=40
ATTEMPT=0
HEALTHY=false

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
	STATUS="$(docker inspect -f '{{.State.Health.Status}}' mc-server 2>/dev/null || echo "starting")"
	if [ "$STATUS" = "healthy" ]; then
		echo "[✓] Minecraft server container is healthy!"
		HEALTHY=true
		break
	fi
	echo "    Health status: '${STATUS}' (attempt $((ATTEMPT + 1))/${MAX_ATTEMPTS})..."
	sleep 6
	ATTEMPT=$((ATTEMPT + 1))
done

if [ "$HEALTHY" != "true" ]; then
	echo "ERROR: Minecraft container failed healthcheck within timeout." >&2
	echo "=== Container Logs ===" >&2
	docker logs --tail 100 mc-server >&2 || true
	exit 1
fi

echo "==> Step 6: Verifying RCON response and player listing format..."
RCON_RESP="$(docker exec mc-server rcon-cli list)"
echo "    RCON Response: ${RCON_RESP}"

if echo "$RCON_RESP" | grep -qiE '(There are|players online)'; then
	echo "[✓] RCON communication and player listing format verified successfully!"
else
	echo "ERROR: RCON response did not match expected player count format." >&2
	exit 1
fi

echo "=========================================================="
echo "Container smoke test passed successfully!"
echo "=========================================================="
