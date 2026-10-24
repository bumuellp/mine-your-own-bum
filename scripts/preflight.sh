#!/usr/bin/env bash
# ==============================================================================
# Pre-flight credential & configuration validator orchestrator
# ==============================================================================
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

init_preflight

echo "=========================================================="
echo " Validating Credentials & Secrets (Local Pre-flight Check)"
echo "=========================================================="

for check in "${SCRIPT_DIR}/preflight.d/"*.sh; do
	[ -f "$check" ] || continue
	# shellcheck source=/dev/null
	source "$check"
done

echo "=========================================================="
if [ "$ALL_OK" -eq 0 ]; then
	echo -e "${GREEN}All pre-flight checks passed! Server is ready to launch.${NC}"
	exit 0
else
	echo -e "${RED}One or more pre-flight checks failed. Please review the errors above.${NC}"
	exit 1
fi
