#!/usr/bin/env bash
# ==============================================================================
# Persistent Volume Bootstrap for Hetzner Cloud
# Detects attached SCSI block volume, formats with ext4 on first attach,
# registers mount in /etc/fstab, and mounts to target directory.
# ==============================================================================
set -euo pipefail

VOLUME_ID="${1:-${VOLUME_ID:-}}"
MOUNT_POINT="${2:-${MOUNT_POINT:-/mnt/mc-data}}"

if [ -n "$VOLUME_ID" ]; then
	DEVICE="/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}"
else
	# Fallback: find any attached Hetzner volume
	DEVICE="$(find /dev/disk/by-id/ -name "scsi-0HC_Volume_*" 2>/dev/null | head -n 1 || true)"
fi

echo "Waiting for persistent block storage device: ${DEVICE:-<unknown>}..."
for i in $(seq 1 30); do
	if [ -n "$DEVICE" ] && [ -b "$DEVICE" ]; then
		echo "Found block device: $DEVICE on attempt $i."
		break
	fi
	sleep 2
	if [ -z "$DEVICE" ]; then
		DEVICE="$(find /dev/disk/by-id/ -name "scsi-0HC_Volume_*" 2>/dev/null | head -n 1 || true)"
	fi
done

if [ -z "$DEVICE" ] || [ ! -b "$DEVICE" ]; then
	echo "ERROR: Persistent block volume device was not found after 60 seconds." >&2
	exit 1
fi

mkdir -p "$MOUNT_POINT"

# Check if filesystem already exists
if ! blkid "$DEVICE" >/dev/null 2>&1; then
	echo "Device $DEVICE is unformatted. Formatting with ext4 (label: mc-data)..."
	mkfs.ext4 -F -L mc-data "$DEVICE"
else
	echo "Existing filesystem detected on $DEVICE. Preserving world data."
fi

# Add persistent mount to /etc/fstab if missing
FSTAB_ENTRY="$DEVICE $MOUNT_POINT ext4 defaults,nofail,discard 0 2"
if ! grep -qs "$MOUNT_POINT" /etc/fstab; then
	echo "Adding persistent mount entry to /etc/fstab..."
	echo "$FSTAB_ENTRY" >>/etc/fstab
fi

# Mount volume and verify
mount -a
mkdir -p "${MOUNT_POINT}/backups"
echo "Persistent volume successfully mounted at ${MOUNT_POINT}."
