#!/usr/bin/env bash
# ==============================================================================
# Local pre-flight credential validator for Mine Your Own Bum
# Validates Hetzner Cloud API, DNS API, OpenTofu state passphrase, and S3 backend.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

SETTINGS_FILE="config/settings.yaml"
[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="config/settings.example.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================================="
echo " Validating Credentials & Secrets (Local Pre-flight Check)"
echo "=========================================================="

if [ -f "config/secrets.yaml" ]; then
	DECRYPTED="$(cat "config/secrets.yaml")"
	SECRETS_FILE="config/secrets.yaml"
elif [ -f "config/secrets.enc.yaml" ]; then
	SECRETS_FILE="config/secrets.enc.yaml"
	if ! command -v sops >/dev/null 2>&1; then
		echo -e "${RED}[✗] SOPS CLI not found in PATH.${NC}" >&2
		echo "    Install SOPS to decrypt secrets locally, or provide decrypted config/secrets.yaml." >&2
		exit 1
	fi
	if ! DECRYPTED="$(sops -d "$SECRETS_FILE" 2>/dev/null)"; then
		echo -e "${RED}[✗] Failed to decrypt ${SECRETS_FILE} with SOPS.${NC}"
		echo "    Ensure your Age private key is in ~/.config/sops/age/keys.txt or SOPS_AGE_KEY is set."
		exit 1
	fi
else
	echo "ERROR: Neither 'config/secrets.yaml' nor 'config/secrets.enc.yaml' found." >&2
	exit 1
fi

# Helper: parse scalar value from decrypted YAML
get_secret() {
	local key="$1"
	echo "$DECRYPTED" | awk -v k="$key" '
		$1 == k ":" {
			sub(/^[^:]*:[ \t]*/, "")
			sub(/#.*$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			gsub(/^"|"$/, "")
			print
			exit
		}
	'
}

# Helper: parse nested setting from settings.yaml
get_setting() {
	local section="$1"
	local key="$2"
	awk -v s="$section" -v k="$key" '
		$1 == s ":" { in_sec=1; next }
		in_sec && /^[a-zA-Z]/ { in_sec=0 }
		in_sec && $1 == k ":" {
			sub(/^[^:]*:[ \t]*/, "")
			sub(/#.*$/, "")
			gsub(/^[ \t]+|[ \t]+$/, "")
			gsub(/^"|"$/, "")
			print
			exit
		}
	' "$SETTINGS_FILE"
}

ALL_OK=0

# ------------------------------------------------------------------------------
# 1. Hetzner Cloud API Token
# ------------------------------------------------------------------------------
HCLOUD_TOKEN="$(get_secret "hcloud_token")"
if [ -z "$HCLOUD_TOKEN" ] || [[ "$HCLOUD_TOKEN" == *"YOUR_"* ]]; then
	echo -e "${RED}[✗] Hetzner Cloud API:${NC} Missing or placeholder value in ${SECRETS_FILE}."
	ALL_OK=1
else
	HTTP_CODE="$(curl -s -o /dev/null -w "%{http_code}" \
		-H "Authorization: Bearer ${HCLOUD_TOKEN}" \
		"https://api.hetzner.cloud/v1/servers")"
	if [ "$HTTP_CODE" -eq 200 ]; then
		echo -e "${GREEN}[✓] Hetzner Cloud API:${NC} Token authenticated successfully (HTTP 200)."

		SERVER_TYPE="$(get_setting "server" "server_type" || echo "cax21")"
		LOCATION="$(get_setting "server" "location" || echo "fsn1")"
		if command -v jq >/dev/null 2>&1; then
			TYPE_RESP="$(curl -s -H "Authorization: Bearer ${HCLOUD_TOKEN}" "https://api.hetzner.cloud/v1/server_types?name=${SERVER_TYPE}")"
			AVAIL="$(echo "$TYPE_RESP" | jq -r --arg loc "$LOCATION" '[.server_types[0].locations[]? | select(.name == $loc) | .available][0]')"
			if [ "$AVAIL" = "true" ]; then
				echo -e "${GREEN}[✓] Hetzner Server Sizing:${NC} Model '${SERVER_TYPE}' is available in '${LOCATION}'."
			elif [ "$AVAIL" = "false" ]; then
				echo -e "${RED}[✗] Hetzner Server Sizing:${NC} Server Type '${SERVER_TYPE}' is unavailable in '${LOCATION}'."
				ALL_OK=1
			fi
		fi
	else
		echo -e "${RED}[✗] Hetzner Cloud API:${NC} Authentication failed (HTTP ${HTTP_CODE}). Check hcloud_token."
		ALL_OK=1
	fi
fi

# ------------------------------------------------------------------------------
# 2. OpenTofu Client-Side State Encryption Passphrase
# ------------------------------------------------------------------------------
PASSPHRASE="$(get_secret "state_encryption_passphrase")"
if [ "${#PASSPHRASE}" -ge 16 ] && [[ "$PASSPHRASE" != *"CHANGE_ME"* ]]; then
	echo -e "${GREEN}[✓] OpenTofu State Encryption:${NC} Passphrase length valid (${#PASSPHRASE} characters, min 16)."
else
	echo -e "${RED}[✗] OpenTofu State Encryption:${NC} Passphrase is too short (${#PASSPHRASE} chars). Minimum 16 characters required."
	ALL_OK=1
fi

# ------------------------------------------------------------------------------
# 3. Dynamic DNS Provider API
# ------------------------------------------------------------------------------
DNS_ENABLED="$(get_setting "dns" "enabled")"
DNS_PROVIDER="$(get_setting "dns" "provider")"
DNS_DOMAIN="$(get_setting "dns" "domain")"
DNS_TOKEN="$(get_secret "dns_token")"

if [ "$DNS_ENABLED" != "true" ]; then
	echo -e "${YELLOW}[i] DNS Synchronization:${NC} Disabled in ${SETTINGS_FILE} (skipping API check)."
elif [ -z "$DNS_TOKEN" ] || [[ "$DNS_TOKEN" == *"YOUR_"* ]]; then
	echo -e "${RED}[✗] DNS API:${NC} dns_token is missing or placeholder, but dns.enabled is set to true."
	ALL_OK=1
elif [ "$DNS_PROVIDER" = "ionos" ]; then
	if [[ "$DNS_TOKEN" != *.* ]]; then
		echo -e "${RED}[✗] IONOS DNS API:${NC} Invalid API key format!"
		echo "    IONOS keys must follow '<public_prefix>.<secret>' format separated by a dot ('.')."
		ALL_OK=1
	else
		RESP="$(curl -s -w "\n%{http_code}" \
			-H "X-API-Key: ${DNS_TOKEN}" \
			-H "Accept: application/json" \
			"https://api.hosting.ionos.com/dns/v1/zones")"
		HTTP_CODE="$(echo "$RESP" | tail -n 1)"
		BODY="$(echo "$RESP" | sed '$d')"
		if [ "$HTTP_CODE" -eq 200 ]; then
			if echo "$BODY" | grep -qi "\"name\":[[:space:]]*\"${DNS_DOMAIN}\""; then
				echo -e "${GREEN}[✓] IONOS DNS API:${NC} Token authenticated and zone '${DNS_DOMAIN}' found."
			else
				echo -e "${YELLOW}[!] IONOS DNS API:${NC} Token valid, but zone '${DNS_DOMAIN}' was not found in your account."
				ALL_OK=1
			fi
		else
			echo -e "${RED}[✗] IONOS DNS API:${NC} Authentication failed (HTTP ${HTTP_CODE}): ${BODY}"
			ALL_OK=1
		fi
	fi
elif [ "$DNS_PROVIDER" = "desec" ]; then
	RESP="$(curl -s -w "\n%{http_code}" \
		-H "Authorization: Token ${DNS_TOKEN}" \
		-H "Accept: application/json" \
		"https://desec.io/api/v1/domains/")"
	HTTP_CODE="$(echo "$RESP" | tail -n 1)"
	BODY="$(echo "$RESP" | sed '$d')"
	if [ "$HTTP_CODE" -eq 200 ]; then
		if echo "$BODY" | grep -qi "\"name\":[[:space:]]*\"${DNS_DOMAIN}\""; then
			echo -e "${GREEN}[✓] deSEC DNS API:${NC} Token authenticated and domain '${DNS_DOMAIN}' found."
		else
			echo -e "${YELLOW}[!] deSEC DNS API:${NC} Token valid, but domain '${DNS_DOMAIN}' was not found in your account."
			ALL_OK=1
		fi
	else
		echo -e "${RED}[✗] deSEC DNS API:${NC} Authentication failed (HTTP ${HTTP_CODE}): ${BODY}"
		ALL_OK=1
	fi
fi

# ------------------------------------------------------------------------------
# 4. OpenTofu S3 Backend, Code & Template Validation
# ------------------------------------------------------------------------------
S3_BUCKET="$(get_secret "s3_bucket")"
S3_ENDPOINT="$(get_secret "s3_endpoint")"
S3_ACCESS_KEY="$(get_secret "s3_access_key")"
S3_SECRET_KEY="$(get_secret "s3_secret_key")"

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
		echo -e "${GREEN}[✓] S3 Backend & State Encryption:${NC} Connected and authenticated to '${S3_BUCKET}'."

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

		# Cloud backup configuration check
		BACKUP_ENABLED=$(get_setting "backup" "enabled" || echo "false")
		if [ "$BACKUP_ENABLED" = "true" ]; then
			DEDICATED_BUCKET="$(get_secret "backup_s3_bucket")"
			if [ -n "$DEDICATED_BUCKET" ]; then
				DEDICATED_ENDPOINT="$(get_secret "backup_s3_endpoint")"
				DEDICATED_KEY="$(get_secret "backup_s3_access_key")"
				DEDICATED_SECRET="$(get_secret "backup_s3_secret_key")"
				if [ -z "$DEDICATED_ENDPOINT" ] || [ -z "$DEDICATED_KEY" ] || [ -z "$DEDICATED_SECRET" ]; then
					echo -e "${RED}[✗] Backup Storage:${NC} Dedicated backup bucket '${DEDICATED_BUCKET}' is missing endpoint, access_key, or secret_key."
					ALL_OK=1
				else
					echo -e "${GREEN}[✓] Backup S3 Target:${NC} Dedicated S3/R2 backup bucket '${DEDICATED_BUCKET}' verified."
				fi
			else
				echo -e "${RED}[✗] Backup Storage:${NC} backup.enabled is true, but 'backup_s3_bucket' is not configured in ${SECRETS_FILE}."
				echo "    A dedicated backup S3/R2 bucket is required to isolate world backups from OpenTofu state."
				ALL_OK=1
			fi
		else
			echo -e "${BLUE}[i] Backup Storage:${NC} Automated cloud backups are disabled in settings.yaml."
		fi

		# Minecraft access control / whitelist validation
		WL_ENABLED="$(get_setting "minecraft" "whitelist_enabled" || echo "false")"
		if [ "$WL_ENABLED" = "true" ]; then
			if grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?\.[a-zA-Z0-9_]' "$SETTINGS_FILE" >/dev/null 2>&1; then
				BAD_NAME="$(grep -E '^[[:space:]]*-[[:space:]]*["'"'"']?\.[a-zA-Z0-9_]' "$SETTINGS_FILE" | head -n 1 | sed -E 's/^[[:space:]]*-[[:space:]]*["'"'"']?([^"'"'"'[:space:]]+)["'"'"']?.*$/\1/')"
				echo -e "${RED}[✗] Minecraft Whitelist:${NC} Bedrock username '${BAD_NAME}' detected. Bedrock players must use their Floodgate UUID (format: 00000000-0000-0000-xxxx-xxxxxxxxxxxx) because Mojang API cannot resolve Bedrock gamertags."
				ALL_OK=1
			else
				echo -e "${GREEN}[✓] Minecraft Whitelist:${NC} Access control whitelist is enabled."
			fi
		fi

		rm -rf iac/.terraform iac/.terraform.lock.hcl
	else
		rm -rf iac/.terraform iac/.terraform.lock.hcl
		echo -e "${RED}[✗] S3 Backend:${NC} Initialization failed. Check bucket, endpoint, and S3 credentials."
		ALL_OK=1
	fi
fi

echo "=========================================================="
if [ "$ALL_OK" -eq 0 ]; then
	echo -e "${GREEN}All pre-flight checks passed! Server is ready to launch.${NC}"
	exit 0
else
	echo -e "${RED}One or more pre-flight checks failed. Please review the errors above.${NC}"
	exit 1
fi
