#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: OpenTofu S3 Backend, State Decryption & Code Validation
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

S3_BUCKET="$(get_secret "s3_bucket")"
S3_ENDPOINT="$(get_secret "s3_endpoint")"
S3_ACCESS_KEY="$(get_secret "s3_access_key")"
S3_SECRET_KEY="$(get_secret "s3_secret_key")"
PASSPHRASE="$(get_secret "state_encryption_passphrase")"
HCLOUD_TOKEN="$(get_secret "hcloud_token")"

if [ -z "$S3_BUCKET" ] || [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
	echo -e "${RED}[✗] S3 Backend:${NC} Missing one or more S3 parameters in ${SECRETS_FILE}."
	ALL_OK=1
else
	export TF_VAR_state_encryption_passphrase="$PASSPHRASE"
	export TF_VAR_hcloud_token="${HCLOUD_TOKEN:-}"

	STATE_KEY="$(awk -F'"' '/key[ \t]*=/ {print $2; exit}' iac/versions.tf)"
	[ -n "$STATE_KEY" ] || STATE_KEY="mine-your-own-bum/terraform.tfstate"

	if (cd iac && tofu init \
		-backend-config="bucket=${S3_BUCKET}" \
		-backend-config="endpoint=${S3_ENDPOINT}" \
		-backend-config="access_key=${S3_ACCESS_KEY}" \
		-backend-config="secret_key=${S3_SECRET_KEY}" \
		-backend-config="key=${STATE_KEY}" \
		-reconfigure >/dev/null 2>&1); then
		echo -e "${GREEN}[✓] S3 Backend & State Encryption:${NC} Connected and authenticated successfully."

		# Test state decryption on the real state file
		if (cd iac && tofu state pull >/dev/null 2>&1); then
			echo -e "${GREEN}[✓] OpenTofu State Decryption:${NC} Remote state '${STATE_KEY}' verified and readable."
		else
			echo -e "${RED}[✗] OpenTofu State Decryption:${NC} Failed to decrypt remote state. Verify state_encryption_passphrase."
			ALL_OK=1
		fi

		# Validate OpenTofu syntax, modules, and .tftpl templates
		if (cd iac && tofu validate >/dev/null 2>&1); then
			echo -e "${GREEN}[✓] OpenTofu Code & Templates:${NC} Configuration and .tftpl templates validated successfully."
		else
			echo -e "${RED}[✗] OpenTofu Validation:${NC} Configuration or template syntax error detected."
			(cd iac && tofu validate)
			ALL_OK=1
		fi

		rm -rf iac/.terraform iac/.terraform.lock.hcl
	else
		rm -rf iac/.terraform iac/.terraform.lock.hcl
		echo -e "${RED}[✗] S3 Backend:${NC} Initialization failed. Check bucket, endpoint, and S3 credentials."
		ALL_OK=1
	fi
fi
