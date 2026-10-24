#!/usr/bin/env bash
# ==============================================================================
# Pre-flight Check: Server Configuration (Keyboard, Storage Sizing & Timeout)
# ==============================================================================
# shellcheck disable=SC1091,SC2034
set -euo pipefail

if [ -z "${REPO_ROOT:-}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=../lib/common.sh
	source "${SCRIPT_DIR}/../lib/common.sh"
	init_preflight
fi

# 1. Console Keyboard Layout
KEYBOARD_LAYOUT="$(get_setting "server" "keyboard_layout")"
if [ -z "$KEYBOARD_LAYOUT" ]; then
	echo -e "${RED}[✗] Server Settings:${NC} 'server.keyboard_layout' is missing in ${SETTINGS_FILE}."
	ALL_OK=1
else
	echo -e "${GREEN}[✓] Server Keyboard:${NC} Console keymap set to '${KEYBOARD_LAYOUT}'."
fi

# 2. Volume Size Sizing
VOLUME_SIZE="$(get_setting "server" "volume_size_gb" || echo "")"
if [ -z "$VOLUME_SIZE" ] || [ "$VOLUME_SIZE" -lt 10 ] 2>/dev/null; then
	echo -e "${RED}[✗] Server Storage:${NC} 'server.volume_size_gb' must be an integer >= 10 GB (found: '${VOLUME_SIZE}')."
	ALL_OK=1
else
	echo -e "${GREEN}[✓] Server Storage:${NC} Persistent storage volume configured for ${VOLUME_SIZE} GB."
fi

# 3. Idle Timeout Configuration
ALWAYS_ON="$(get_setting "server" "always_on" || echo "false")"
IDLE_TIMEOUT="$(get_setting "server" "idle_timeout_minutes" || echo "")"
if [ "$ALWAYS_ON" != "true" ]; then
	if [ -z "$IDLE_TIMEOUT" ] || [ "$IDLE_TIMEOUT" -lt 1 ] 2>/dev/null; then
		echo -e "${RED}[✗] Server Idle Watchdog:${NC} 'server.idle_timeout_minutes' must be an integer >= 1 (found: '${IDLE_TIMEOUT}')."
		ALL_OK=1
	else
		echo -e "${GREEN}[✓] Server Idle Watchdog:${NC} Auto-shutdown timeout configured for ${IDLE_TIMEOUT} minutes."
	fi
else
	echo -e "${BLUE}[i] Server Idle Watchdog:${NC} Server is configured as always-on (idle shutdown disabled)."
fi
