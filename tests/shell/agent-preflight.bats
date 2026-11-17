#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=scripts/lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"

    SETTINGS_FILE="${BATS_TEST_TMPDIR}/settings.yaml"
    SECRETS_FILE="mock-secrets.yaml"
    echo "server:" >"$SETTINGS_FILE"
    ALL_OK=0
}

@test "80-agent passes when tunnel and webhooks are empty (graceful degradation)" {
    DECRYPTED=""
    source "${REPO_ROOT}/scripts/preflight.d/80-agent.sh"
    [ "$ALL_OK" -eq 0 ]
}

@test "80-agent fails when cloudflare_tunnel_token is set without agent_shared_secret" {
    DECRYPTED="$(cat <<'EOF'
cloudflare_tunnel_token: "eyJhIjoiMTIzNDU2In0="
agent_shared_secret: ""
EOF
)"
    source "${REPO_ROOT}/scripts/preflight.d/80-agent.sh"
    [ "$ALL_OK" -eq 1 ]
}

@test "80-agent fails when discord_chat_webhook_url has invalid scheme/prefix" {
    DECRYPTED="$(cat <<'EOF'
cloudflare_tunnel_token: "eyJhIjoiMTIzNDU2In0="
agent_shared_secret: "0123456789abcdef0123456789abcdef"
discord_chat_webhook_url: "https://example.com/not-a-discord-webhook"
EOF
)"
    source "${REPO_ROOT}/scripts/preflight.d/80-agent.sh"
    [ "$ALL_OK" -eq 1 ]
}

@test "80-agent passes when valid tunnel token, secret, and discord webhooks are configured" {
    DECRYPTED="$(cat <<'EOF'
cloudflare_tunnel_token: "eyJhIjoiMTIzNDU2In0="
agent_shared_secret: "0123456789abcdef0123456789abcdef"
discord_chat_webhook_url: "https://discord.com/api/webhooks/123456/abcdef"
discord_command_webhook_url: "https://discordapp.com/api/webhooks/789012/ghijkl"
EOF
)"
    source "${REPO_ROOT}/scripts/preflight.d/80-agent.sh"
    [ "$ALL_OK" -eq 0 ]
}
