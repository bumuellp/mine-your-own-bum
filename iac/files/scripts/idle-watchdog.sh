#!/usr/bin/env bash
# ==============================================================================
# Idle Watchdog Daemon for Mine Your Own Bum
# Polls active players via RCON. Flushes chunks cleanly and dispatches GitHub Actions
# stop workflow when player count remains 0 for consecutive polling intervals.
# ==============================================================================
set -euo pipefail

log_console() {
	echo "[mc-watchdog] $*" | tee -a /dev/kmsg /dev/console 2>/dev/null || echo "[mc-watchdog] $*"
}

trap 'log_console "[FATAL] Watchdog failed at line $LINENO (exit code: $?)"' ERR

# Source configuration file if present
if [ -f "/etc/default/minecraft-watchdog" ]; then
	# shellcheck disable=SC1091
	. "/etc/default/minecraft-watchdog"
fi

ALWAYS_ON="${ALWAYS_ON:-false}"
IDLE_TIMEOUT_MINUTES="${IDLE_TIMEOUT_MINUTES:-15}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_PAT="${GITHUB_PAT:-}"
STATE_FILE="/var/run/mc-idle-counter"
PENDING_STOP_FILE="/var/run/mc-idle-stopping"

if [ "$ALWAYS_ON" = "true" ]; then
	exit 0
fi

dispatch_stop_workflow() {
	if [ -n "$GITHUB_PAT" ] && [ -n "$GITHUB_REPOSITORY" ]; then
		log_console "Dispatching GitHub Actions stop workflow on repository '${GITHUB_REPOSITORY}'..."
		if curl --fail --retry 3 --retry-delay 5 --max-time 15 -sS -X POST \
			-H "Accept: application/vnd.github+json" \
			-H "Authorization: Bearer ${GITHUB_PAT}" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/server-stop.yml/dispatches" \
			-d '{"ref":"main"}'; then
			log_console "GitHub Actions stop workflow dispatched successfully."
			rm -f "$STATE_FILE" "$PENDING_STOP_FILE"
			return 0
		else
			log_console "ERROR: Failed to dispatch stop workflow to GitHub API. Will retry on next interval."
			return 1
		fi
	else
		log_console "WARN: GITHUB_PAT or GITHUB_REPOSITORY not configured. Skipping workflow dispatch."
		rm -f "$STATE_FILE" "$PENDING_STOP_FILE"
		return 0
	fi
}

# If a stop is already pending (e.g. previous dispatch attempt failed), retry immediately
if [ -f "$PENDING_STOP_FILE" ]; then
	log_console "Pending stop detected from previous interval. Retrying GitHub Actions dispatch..."
	dispatch_stop_workflow
	exit 0
fi

# Ensure docker container mc-server is active
if ! docker ps -q --filter "name=mc-server" | grep -q .; then
	exit 0
fi

# Query player count via RCON
RCON_OUTPUT="$(docker exec mc-server rcon-cli list 2>/dev/null || true)"
if [ -z "$RCON_OUTPUT" ]; then
	# Server might still be starting up
	exit 0
fi

# PaperMC output: "There are X of a max of Y players online: ..."
PLAYER_COUNT="$(echo "$RCON_OUTPUT" | grep -oP 'There are \K[0-9]+' || echo "$RCON_OUTPUT" | grep -oE '[0-9]+' | head -n 1 || echo "")"

if [ -z "$PLAYER_COUNT" ]; then
	exit 0
fi

if [ "$PLAYER_COUNT" -gt 0 ]; then
	echo "0" >"$STATE_FILE"
	exit 0
fi

CURRENT_TICKS=0
if [ -f "$STATE_FILE" ]; then
	CURRENT_TICKS="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
fi
CURRENT_TICKS=$((CURRENT_TICKS + 1))
echo "$CURRENT_TICKS" >"$STATE_FILE"

echo "Idle Watchdog: 0 players online. Idle ticks: ${CURRENT_TICKS}/${IDLE_TIMEOUT_MINUTES}"

if [ "$CURRENT_TICKS" -ge "$IDLE_TIMEOUT_MINUTES" ]; then
	log_console "Idle timeout reached (${IDLE_TIMEOUT_MINUTES}m). Initiating graceful shutdown..."
	touch "$PENDING_STOP_FILE"

	# 1. Broadcast warning
	docker exec mc-server rcon-cli say "Server idle for ${IDLE_TIMEOUT_MINUTES} minutes. Stopping..." || true
	sleep 5

	# 2. Clean stop flushes chunks and world data cleanly
	docker exec mc-server rcon-cli stop || true
	sleep 10

	# 3. If backup sidecar is active, trigger session-end snapshot
	if docker ps -q --filter "name=mc-backup" | grep -q .; then
		log_console "Triggering session-end backup via mc-backup..."
		docker exec mc-backup backup-now || true
	fi

	# 4. Stop container stack
	docker stop mc-backup || true
	docker stop mc-server || true

	# 5. Trigger GitHub Actions stop workflow
	dispatch_stop_workflow
fi
