#!/usr/bin/env bash
# ==============================================================================
# Generate GitHub Actions Step Summary for Server Stop
# Formats teardown summary markdown and outputs to $GITHUB_STEP_SUMMARY.
# ==============================================================================
set -euo pipefail

FQDN="${FQDN:-}"
ALREADY_STOPPED="${ALREADY_STOPPED:-false}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
REASON="${REASON:-manual}"

STOP_REASON="The server was manually shut down via workflow dispatch."
if [ "$ALREADY_STOPPED" = "true" ]; then
	STOP_REASON="The server was already offline; no compute teardown was needed."
elif [ "$REASON" = "idle-watchdog" ]; then
	STOP_REASON="The server was automatically shut down by the **Idle Watchdog** because no players were active."
fi

DNS_ROW=""
if [ -n "$FQDN" ]; then
	DNS_ROW="- **DNS Record**: \`${FQDN}\` entry removed."
fi

cat <<EOF >>"$SUMMARY_FILE"
## 🛑 Minecraft Server Status: **OFFLINE**

${STOP_REASON}

### 💾 State Preservation
- **Compute Instance**: Terminated to halt compute charges.
- **Persistent Volume**: Safe & retained on Hetzner Cloud.
${DNS_ROW}

To play again, trigger the **Start Minecraft Server** workflow.
EOF
