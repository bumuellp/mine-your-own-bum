#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: State Passphrase, Console Password & Watchdog PAT
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

# 1. OpenTofu Client-Side State Encryption Passphrase
PASSPHRASE="$(get_secret "state_encryption_passphrase")"
if [ "${#PASSPHRASE}" -ge 16 ] && [[ "$PASSPHRASE" != *"CHANGE_ME"* ]]; then
	echo -e "${GREEN}[✓] OpenTofu State Encryption:${NC} Passphrase length valid (${#PASSPHRASE} characters, min 16)."
else
	echo -e "${RED}[✗] OpenTofu State Encryption:${NC} Passphrase is too short (${#PASSPHRASE} chars). Minimum 16 characters required."
	ALL_OK=1
fi

# 2. Console Root Password
CONSOLE_PASS="$(get_secret "console_password")"
if [ -z "$CONSOLE_PASS" ] || [[ "$CONSOLE_PASS" == *"CHANGE_ME"* ]]; then
	echo -e "${RED}[✗] Console Password:${NC} 'console_password' is missing or placeholder in ${SECRETS_FILE}."
	ALL_OK=1
else
	echo -e "${GREEN}[✓] Console Password:${NC} Web console root password verified."
fi

# 3. Idle Watchdog GitHub PAT (auto-stop dispatch)
ALWAYS_ON_SETTING="$(get_setting "server" "always_on" || echo "false")"
WATCHDOG_PAT="${PAT_WATCHDOG:-$(get_secret "github_pat")}"
TARGET_REPO="${GITHUB_REPOSITORY:-}"
if [ -z "$TARGET_REPO" ]; then
	TARGET_REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"
fi

if [ "$ALWAYS_ON_SETTING" = "true" ]; then
	echo -e "${BLUE}[i] Idle Watchdog:${NC} always_on is true (auto-stop disabled, skipping PAT check)."
elif [ -z "$WATCHDOG_PAT" ] || [[ "$WATCHDOG_PAT" == *"YOUR_"* ]]; then
	echo -e "${YELLOW}[!] Idle Watchdog:${NC} No github_pat configured. Idle server will stop Minecraft but the VM will NOT be destroyed (keeps billing)."
elif [ -z "$TARGET_REPO" ]; then
	echo -e "${YELLOW}[!] Idle Watchdog:${NC} Could not determine GitHub repository (set GITHUB_REPOSITORY). Skipping PAT check."
else
	PAT_HTTP="$(curl -s -o /dev/null -w "%{http_code}" \
		-H "Authorization: Bearer ${WATCHDOG_PAT}" \
		-H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/${TARGET_REPO}/actions/workflows/server-stop.yml")"
	if [ "$PAT_HTTP" = "200" ]; then
		echo -e "${GREEN}[✓] Idle Watchdog PAT:${NC} Token can access '${TARGET_REPO}' server-stop.yml workflow."
	else
		echo -e "${RED}[✗] Idle Watchdog PAT:${NC} Token cannot access '${TARGET_REPO}' (HTTP ${PAT_HTTP})."
		echo "    Grant the fine-grained PAT access to this repository with 'Actions: Read and write' permission."
		ALL_OK=1
	fi
fi
