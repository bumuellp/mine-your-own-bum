#!/usr/bin/env bash
# ==============================================================================
# Local pre-flight credential validator for Mine Your Own Bum
# Validates Hetzner Cloud API, DNS API, OpenTofu state passphrase, and S3 backend.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

SECRETS_FILE="config/secrets.enc.yaml"
SETTINGS_FILE="config/settings.yaml"

if [ ! -f "$SECRETS_FILE" ]; then
	echo "ERROR: '${SECRETS_FILE}' not found. Please create and encrypt it first." >&2
	exit 1
fi

[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="config/settings.example.yaml"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================================="
echo " Validating Credentials & Secrets (Local Pre-flight Check)"
echo "=========================================================="

# 1. Decrypt secrets safely into memory
if ! DECRYPTED="$(sops -d "$SECRETS_FILE" 2>/dev/null)"; then
	echo -e "${RED}[✗] Failed to decrypt ${SECRETS_FILE} with SOPS.${NC}"
	echo "    Ensure your Age private key is in ~/.config/sops/age/keys.txt or SOPS_AGE_KEY is set."
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

	if (cd iac && tofu init \
		-backend-config="bucket=${S3_BUCKET}" \
		-backend-config="endpoint=${S3_ENDPOINT}" \
		-backend-config="access_key=${S3_ACCESS_KEY}" \
		-backend-config="secret_key=${S3_SECRET_KEY}" \
		-backend-config="key=$(basename "$REPO_ROOT")/terraform.tfstate" \
		-reconfigure >/dev/null 2>&1); then
		echo -e "${GREEN}[✓] S3 Backend & State Encryption:${NC} Connected and authenticated to '${S3_BUCKET}'."

		# Validate OpenTofu syntax, modules, and .tftpl templates
		if (cd iac && tofu validate >/dev/null 2>&1); then
			echo -e "${GREEN}[✓] OpenTofu Code & Templates:${NC} Configuration and .tftpl templates validated successfully."
		else
			echo -e "${RED}[✗] OpenTofu Validation:${NC} Configuration or template syntax error detected."
			(cd iac && tofu validate)
			ALL_OK=1
		fi

		# Cloud-Init schema check (if cloud-init CLI is installed)
		if command -v cloud-init >/dev/null 2>&1; then
			RENDERED_INIT="$(mktemp)"
			if (cd iac && tofu console <<<'local.cloud_init' 2>/dev/null | sed -e 's/^"//' -e 's/"$//' -e 's/\\n/\n/g' -e 's/\\"/"/g' >"$RENDERED_INIT"); then
				if cloud-init schema --config-file "$RENDERED_INIT" >/dev/null 2>&1; then
					echo -e "${GREEN}[✓] Cloud-Init Schema:${NC} Rendered guest payload passed cloud-init schema check."
				fi
			fi
			rm -f "$RENDERED_INIT"
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
