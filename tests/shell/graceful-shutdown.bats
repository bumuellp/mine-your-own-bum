#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SHUTDOWN_SCRIPT="${REPO_ROOT}/.github/scripts/graceful-shutdown.sh"

    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="${MOCK_BIN}:${PATH}"

    export CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
    export POLL_COUNT_FILE="${BATS_TEST_TMPDIR}/poll_count"
    echo "0" >"$POLL_COUNT_FILE"
    : >"$CURL_LOG"

    cat <<'EOF' >"${MOCK_BIN}/sleep"
#!/usr/bin/env bash
exit 0
EOF

    cat <<'EOF' >"${MOCK_BIN}/curl"
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
if [[ "$*" == *"/actions/shutdown"* ]]; then
    printf '{"action":{"id":1}}\n201\n'
    exit 0
fi

count="$(cat "$POLL_COUNT_FILE")"
count=$((count + 1))
echo "$count" >"$POLL_COUNT_FILE"

if [ "${MOCK_INITIAL_STATUS:-running}" = "already_off" ]; then
    printf '{"server":{"status":"off"}}\n200\n'
elif [ "${MOCK_INITIAL_STATUS:-running}" = "api_error" ]; then
    printf '{"error":"server_error"}\n500\n'
elif [ "$count" -eq 1 ]; then
    printf '{"server":{"status":"running"}}\n200\n'
else
    printf '{"server":{"status":"off"}}\n'
fi
exit 0
EOF

    chmod +x "${MOCK_BIN}/sleep" "${MOCK_BIN}/curl"
}

@test "graceful-shutdown exits 0 when SERVER_ID or HCLOUD_TOKEN is missing" {
    SERVER_ID="" HCLOUD_TOKEN="tok" run "$SHUTDOWN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping ACPI shutdown"* ]]
}

@test "graceful-shutdown exits 0 without error when Hetzner API returns HTTP 500" {
    export SERVER_ID="12345"
    export HCLOUD_TOKEN="tok_test"
    export MOCK_INITIAL_STATUS="api_error"

    run "$SHUTDOWN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"HTTP 500"* ]]
    ! grep -q "/actions/shutdown" "$CURL_LOG"
}

@test "graceful-shutdown skips POST /actions/shutdown when server is already off" {
    export SERVER_ID="12345"
    export HCLOUD_TOKEN="tok_test"
    export MOCK_INITIAL_STATUS="already_off"

    run "$SHUTDOWN_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"currently 'off'"* ]]
    ! grep -q "/actions/shutdown" "$CURL_LOG"
}

@test "graceful-shutdown dispatches POST /actions/shutdown and polls until off when running" {
    export SERVER_ID="12345"
    export HCLOUD_TOKEN="tok_test"
    export MOCK_INITIAL_STATUS="running"

    run "$SHUTDOWN_SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "/actions/shutdown" "$CURL_LOG"
    [[ "$output" == *"shut down cleanly"* ]]
}
