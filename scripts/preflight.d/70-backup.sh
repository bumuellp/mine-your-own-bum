#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Dedicated S3/R2 Backup Storage
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

BACKUP_ENABLED=$(get_setting "backup" "enabled" || echo "false")
if [ "$BACKUP_ENABLED" = "true" ]; then
	DEDICATED_BUCKET="$(get_secret "backup_s3_bucket")"
	if [ -n "$DEDICATED_BUCKET" ]; then
		DEDICATED_ENDPOINT="$(get_secret "backup_s3_endpoint")"
		DEDICATED_KEY="$(get_secret "backup_s3_access_key")"
		DEDICATED_SECRET="$(get_secret "backup_s3_secret_key")"
		if [ -z "$DEDICATED_ENDPOINT" ] || [ -z "$DEDICATED_KEY" ] || [ -z "$DEDICATED_SECRET" ]; then
			echo -e "${RED}[✗] Backup Storage:${NC} Dedicated backup bucket is missing endpoint, access_key, or secret_key."
			ALL_OK=1
		else
			echo -e "${GREEN}[✓] Backup S3 Target:${NC} Dedicated S3/R2 backup bucket verified."
		fi
	else
		echo -e "${RED}[✗] Backup Storage:${NC} backup.enabled is true, but 'backup_s3_bucket' is not configured in ${SECRETS_FILE}."
		echo "    A dedicated backup S3/R2 bucket is required to isolate world backups from OpenTofu state."
		ALL_OK=1
	fi
else
	echo -e "${BLUE}[i] Backup Storage:${NC} Automated cloud backups are disabled in settings.yaml."
fi
