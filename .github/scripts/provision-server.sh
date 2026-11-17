#!/usr/bin/env bash
# ==============================================================================
# Provision Minecraft Server via OpenTofu
# Ensures persistent storage volume exists before provisioning compute instance.
# Exports outputs to $GITHUB_OUTPUT.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IAC_DIR="${REPO_ROOT}/iac"

cd "${IAC_DIR}"

ALREADY_RUNNING=false
if tofu state list module.server.hcloud_server.this >/dev/null 2>&1; then
	ALREADY_RUNNING=true
	echo "Minecraft server instance is already running in remote state."
else
	# Ensure persistent storage volume exists before provisioning compute and attachments
	if ! tofu state list module.volume.hcloud_volume.this >/dev/null 2>&1; then
		echo "Persistent volume not found in remote state; creating volume first..."
		tofu apply -target=module.volume -auto-approve
	fi
	tofu apply -auto-approve
fi

TOFU_OUT="$(tofu output -json)"
DNS_TOKEN="$(echo "$TOFU_OUT" | jq -r '.dns_token.value // ""')"
if [ -n "$DNS_TOKEN" ]; then
	echo "::add-mask::$DNS_TOKEN"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "already_running=${ALREADY_RUNNING}"
		echo "ipv4=$(echo "$TOFU_OUT" | jq -r '.server_ipv4.value // ""')"
		echo "ipv6=$(echo "$TOFU_OUT" | jq -r '.server_ipv6.value // ""')"
		echo "server_type=$(echo "$TOFU_OUT" | jq -r '.server_type.value // ""')"
		echo "server_arch=$(echo "$TOFU_OUT" | jq -r '.server_architecture.value // ""')"
		echo "dns_enabled=$(echo "$TOFU_OUT" | jq -r '.dns_enabled.value // false')"
		echo "dns_provider=$(echo "$TOFU_OUT" | jq -r '.dns_provider.value // ""')"
		echo "dns_domain=$(echo "$TOFU_OUT" | jq -r '.dns_domain.value // ""')"
		echo "dns_subname=$(echo "$TOFU_OUT" | jq -r '.dns_subname.value // ""')"
		echo "dns_ttl=$(echo "$TOFU_OUT" | jq -r '.dns_ttl.value // 60')"
		echo "dns_fqdn=$(echo "$TOFU_OUT" | jq -r '.dns_fqdn.value // ""')"
		echo "dns_token=${DNS_TOKEN}"
	} >>"$GITHUB_OUTPUT"
fi
