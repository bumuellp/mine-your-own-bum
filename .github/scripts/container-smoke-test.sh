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
COMPOSE_ACTIVE_FILE="${REPO_ROOT}/docker-compose.active.yml"
COMPOSE_MODPACK_FILE="${REPO_ROOT}/docker-compose.modpack.yml"
CLOUD_INIT_FILE="${REPO_ROOT}/cloud-init.yaml"
MOUNT_DIR="/mnt/mc-data"

cleanup() {
	echo "==> Cleaning up smoke test resources..."
	for f in "$COMPOSE_ACTIVE_FILE" "$COMPOSE_FILE"; do
		if [ -f "$f" ]; then
			docker compose -f "$f" down -v --remove-orphans >/dev/null 2>&1 || true
		fi
	done
	rm -f "$COMPOSE_FILE" "$COMPOSE_ACTIVE_FILE" "$COMPOSE_MODPACK_FILE" "$CLOUD_INIT_FILE"
	if [ -d "$MOUNT_DIR" ]; then
		if [ -n "${GITHUB_ACTIONS:-}" ]; then
			# Preserve downloaded mods, libraries, and patched loader jars for actions/cache
			sudo rm -rf "${MOUNT_DIR}/world"* "${MOUNT_DIR}/logs" "${MOUNT_DIR}/backups" "${MOUNT_DIR}/"*.lock 2>/dev/null || true
			sudo chown -R "$(id -u):$(id -g)" "$MOUNT_DIR" 2>/dev/null || true
			sudo chmod -R u+rwX "$MOUNT_DIR" 2>/dev/null || true
		else
			sudo rm -rf "$MOUNT_DIR" 2>/dev/null || rm -rf "$MOUNT_DIR" 2>/dev/null || true
		fi
	fi
	rm -rf "${REPO_ROOT}/tests/smoke-test/.terraform"* "${REPO_ROOT}/tests/smoke-test/terraform.tfstate"* >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "==> Step 1: Rendering Docker Compose & Cloud-Init specifications via OpenTofu..."
if [ -n "${TF_PLUGIN_CACHE_DIR:-}" ]; then
	mkdir -p "$TF_PLUGIN_CACHE_DIR"
fi

REAL_CF_KEY="${CF_API_KEY:-}"
if [ -z "$REAL_CF_KEY" ] && [ -f "${REPO_ROOT}/config/secrets.enc.yaml" ] && command -v sops >/dev/null 2>&1; then
	REAL_CF_KEY="$(sops -d --extract '["cf_api_key"]' "${REPO_ROOT}/config/secrets.enc.yaml" 2>/dev/null || echo "")"
fi
if [ -n "$REAL_CF_KEY" ]; then
	[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::${REAL_CF_KEY}"
	export TF_VAR_cf_api_key="$REAL_CF_KEY"
fi

tofu -chdir=tests/smoke-test init -input=false >/dev/null
tofu -chdir=tests/smoke-test apply -auto-approve -input=false >/dev/null
tofu -chdir=tests/smoke-test output -raw docker_compose >"$COMPOSE_FILE"
tofu -chdir=tests/smoke-test output -raw docker_compose_active >"$COMPOSE_ACTIVE_FILE"
tofu -chdir=tests/smoke-test output -raw docker_compose_modpack >"$COMPOSE_MODPACK_FILE"
tofu -chdir=tests/smoke-test output -raw cloud_init >"$CLOUD_INIT_FILE"

echo "==> Step 2: Validating Docker Compose & Cloud-Init syntax..."
docker compose -f "$COMPOSE_FILE" config >/dev/null
docker compose -f "$COMPOSE_ACTIVE_FILE" config >/dev/null
docker compose -f "$COMPOSE_MODPACK_FILE" config >/dev/null
grep -q "^#cloud-config" "$CLOUD_INIT_FILE"
grep -q "CURSEFORGE_FILES:" "$COMPOSE_MODPACK_FILE"
grep -q "MODRINTH_MODPACK_VERSION_TYPE: \"beta\"" "$COMPOSE_MODPACK_FILE"
grep -q "MODRINTH_EXCLUDE_FILES:" "$COMPOSE_MODPACK_FILE"
grep -q "MODRINTH_DOWNLOAD_DEPENDENCIES: \"required\"" "$COMPOSE_MODPACK_FILE"
echo "[✓] Docker Compose (baseline + active settings + synthetic matrix) and Cloud-Init syntax valid."

echo "==> Step 2b: Validating active settings Modrinth modpack & project resolution..."
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
if [ -f "${REPO_ROOT}/config/settings.yaml" ]; then
	export SETTINGS_FILE="${REPO_ROOT}/config/settings.yaml"
else
	export SETTINGS_FILE="${REPO_ROOT}/config/settings.example.yaml"
fi
export SECRETS_FILE="${REPO_ROOT}/config/secrets.example.yaml"
export DECRYPTED="auth_password: \"smoke-test-auth\"
cf_api_key: \"smoke-test-cf-key\""
ALL_OK=0
# shellcheck source=scripts/preflight.d/60-minecraft.sh
source "${REPO_ROOT}/scripts/preflight.d/60-minecraft.sh"
if [ "$ALL_OK" -ne 0 ]; then
	echo "ERROR: Active settings failed Minecraft / Modrinth preflight validation." >&2
	exit 1
fi

echo "==> Step 3: Preparing persistent mount directory..."
if command -v sudo >/dev/null 2>&1; then
	sudo mkdir -p "$MOUNT_DIR"
	sudo chmod 777 "$MOUNT_DIR"
else
	mkdir -p "$MOUNT_DIR"
	chmod 777 "$MOUNT_DIR"
fi

if [ -d "${MOUNT_DIR}/mods" ]; then
	while IFS= read -r excl; do
		[ -z "$excl" ] && continue
		sudo find "${MOUNT_DIR}/mods" -maxdepth 1 -type f -iname "*${excl}*" -delete 2>/dev/null || find "${MOUNT_DIR}/mods" -maxdepth 1 -type f -iname "*${excl}*" -delete 2>/dev/null || true
	done < <(cfg_list '.minecraft.modrinth_exclude_files')
fi

echo "==> Step 4: Launching Minecraft test container..."
BOOT_COMPOSE="$COMPOSE_FILE"
if [ -f "${REPO_ROOT}/config/settings.yaml" ]; then
	BOOT_COMPOSE="$COMPOSE_ACTIVE_FILE"
	if [ -n "$REAL_CF_KEY" ]; then
		echo "    Booting active repository configuration (config/settings.yaml with CurseForge API key)..."
	else
		echo "    Booting active repository configuration (config/settings.yaml; CurseForge projects skipped without API key)..."
	fi
fi
docker compose -f "$BOOT_COMPOSE" up -d mc-server

echo "==> Step 5: Awaiting engine initialization and healthcheck..."
MAX_ATTEMPTS=60 # 60 * 6s = 360s (covers cold modpack download + NeoForge patching + worldgen)
ATTEMPT=0
HEALTHY=false

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
	STATUS="$(docker inspect -f '{{.State.Health.Status}}' mc-server 2>/dev/null || echo "starting")"
	if [ "$STATUS" = "healthy" ]; then
		echo "[✓] Minecraft server container is healthy!"
		HEALTHY=true
		break
	fi

	RESTART_COUNT="$(docker inspect -f '{{.State.RestartCount}}' mc-server 2>/dev/null || echo "0")"
	CONTAINER_STATUS="$(docker inspect -f '{{.State.Status}}' mc-server 2>/dev/null || echo "running")"
	if [ "$RESTART_COUNT" -ge 1 ] || [ "$CONTAINER_STATUS" = "restarting" ] || [ "$CONTAINER_STATUS" = "exited" ]; then
		echo "ERROR: Minecraft container entered crashloop (status: '${CONTAINER_STATUS}', restarts: ${RESTART_COUNT})." >&2
		echo "=== Container Logs ===" >&2
		docker logs --tail 100 mc-server >&2 || true
		exit 1
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
