#!/usr/bin/env bash
# ==============================================================================
# Refresh OpenTofu State & Parse Stop Configuration
# Determines whether the server is already stopped and extracts DNS/server outputs.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IAC_DIR="${REPO_ROOT}/iac"

cd "${IAC_DIR}"

tofu refresh

ALREADY_STOPPED=false
if ! tofu state list module.server.hcloud_server.this >/dev/null 2>&1; then
	ALREADY_STOPPED=true
	echo "Minecraft server instance is already absent from remote state."
fi

TOFU_OUT="$(tofu output -json)"
SERVER_ID="$(echo "$TOFU_OUT" | jq -r '.server_id.value // ""')"
DNS_TOKEN="$(echo "$TOFU_OUT" | jq -r '.dns_token.value // ""')"
if [ -n "$DNS_TOKEN" ]; then
	echo "::add-mask::$DNS_TOKEN"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "already_stopped=${ALREADY_STOPPED}"
		echo "server_id=${SERVER_ID}"
		echo "enabled=$(echo "$TOFU_OUT" | jq -r '.dns_enabled.value // false')"
		echo "provider=$(echo "$TOFU_OUT" | jq -r '.dns_provider.value // ""')"
		echo "domain=$(echo "$TOFU_OUT" | jq -r '.dns_domain.value // ""')"
		echo "subname=$(echo "$TOFU_OUT" | jq -r '.dns_subname.value // ""')"
		echo "fqdn=$(echo "$TOFU_OUT" | jq -r '.dns_fqdn.value // ""')"
		echo "dns_token=${DNS_TOKEN}"
	} >>"$GITHUB_OUTPUT"
fi
