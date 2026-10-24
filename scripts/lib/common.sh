#!/usr/bin/env bash
# ==============================================================================
# Common library for pre-flight validation scripts
# ==============================================================================
# shellcheck disable=SC2034
set -euo pipefail

# ANSI color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize shared paths, settings, and decrypted secrets
init_preflight() {
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
	cd "${REPO_ROOT}"

	SETTINGS_FILE="config/settings.yaml"
	[ -f "$SETTINGS_FILE" ] || SETTINGS_FILE="config/settings.example.yaml"

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

	ALL_OK=0

	# If running inside GitHub Actions, automatically mask all decrypted secrets from CI logs
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		while IFS= read -r secret_val; do
			[ -n "$secret_val" ] || continue
			echo "::add-mask::${secret_val}"
		done < <(echo "$DECRYPTED" | awk '
			/^[a-zA-Z0-9_]+:[ \t]*.+/ {
				sub(/^[a-zA-Z0-9_]+:[ \t]*/, "")
				sub(/#.*$/, "")
				gsub(/^[ \t]+|[ \t]+$/, "")
				gsub(/^"|"$/, "")
				gsub(/^\x27|\x27$/, "")
				if (length($0) > 3) print
			}
		')
	fi
}

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

# Helper: parse nested scalar setting from settings.yaml
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

# Helper: parse YAML list from settings.yaml (supports multiline and inline [a, b])
get_setting_list() {
	local section="$1"
	local key="$2"
	awk -v s="$section" -v k="$key" '
		$1 == s ":" { in_sec=1; next }
		in_sec && /^[a-zA-Z]/ { in_sec=0 }
		in_sec && $1 == k ":" {
			line = $0
			sub(/^[^:]*:[ \t]*/, "", line)
			sub(/#.*$/, "", line)
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line ~ /^\[.*\]/) {
				sub(/^\[/, "", line)
				sub(/\]$/, "", line)
				n = split(line, items, ",")
				for (i = 1; i <= n; i++) {
					item = items[i]
					gsub(/^[ \t]+|[ \t]+$/, "", item)
					gsub(/^"|"$/, "", item)
					gsub(/^\x27|\x27$/, "", item)
					if (length(item) > 0) print item
				}
				exit
			}
			in_list=1
			next
		}
		in_list && /^[[:space:]]*-/ {
			item = $0
			sub(/^[[:space:]]*-[[:space:]]*/, "", item)
			sub(/#.*$/, "", item)
			gsub(/^[ \t]+|[ \t]+$/, "", item)
			gsub(/^"|"$/, "", item)
			gsub(/^\x27|\x27$/, "", item)
			if (length(item) > 0) print item
			next
		}
		in_list && /^[[:space:]]*[a-zA-Z]/ { in_list=0 }
	' "$SETTINGS_FILE"
}
