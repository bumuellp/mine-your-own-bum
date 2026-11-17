#!/usr/bin/env bash
# ==============================================================================
# Prune Remote Rclone Backups by Retention Count
# Invoked by itzg/mc-backup via POST_BACKUP_SCRIPT_FILE after each backup cycle.
# Arguments passed by itzg/mc-backup:
#   $1 - backup_status (0 on success, non-zero on failure)
#   $2 - backup_log path
# ==============================================================================
set -euo pipefail

BACKUP_STATUS="${1:-0}"
RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-${PRUNE_BACKUPS_COUNT:-0}}"
BACKUP_PREFIX="${BACKUP_NAME:-world}"

# Do not prune existing remote backups if the latest backup attempt failed
if [ "$BACKUP_STATUS" -ne 0 ]; then
	echo "WARN: Backup exited with status ${BACKUP_STATUS}; skipping remote rclone prune." >&2
	exit 0
fi

# Validate retention count is a positive integer
if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]] || [ "$RETENTION_COUNT" -le 0 ]; then
	exit 0
fi

if [ -z "${RCLONE_REMOTE:-}" ] || [ -z "${RCLONE_DEST_DIR:-}" ]; then
	echo "WARN: RCLONE_REMOTE or RCLONE_DEST_DIR not set; skipping remote rclone prune." >&2
	exit 0
fi

REMOTE_PATH="${RCLONE_REMOTE}:${RCLONE_DEST_DIR%/}"

mapfile -t EXCESS_BACKUPS < <(
	rclone lsf --files-only "$REMOTE_PATH" |
		grep -E "^${BACKUP_PREFIX}-[0-9]{8}-[0-9]{6}\." |
		sort -r |
		tail -n +"$((RETENTION_COUNT + 1))"
)

if [ "${#EXCESS_BACKUPS[@]}" -eq 0 ]; then
	exit 0
fi

echo "INFO: Pruning ${#EXCESS_BACKUPS[@]} remote backup(s) to retain latest ${RETENTION_COUNT}..."
for old_backup in "${EXCESS_BACKUPS[@]}"; do
	[ -z "$old_backup" ] && continue
	echo "INFO: Removing remote backup ${REMOTE_PATH}/${old_backup}"
	rclone deletefile "${REMOTE_PATH}/${old_backup}"
done
