#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    WATCHDOG_SCRIPT="${REPO_ROOT}/iac/files/scripts/idle-watchdog.sh"

    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="${MOCK_BIN}:${PATH}"

    export STATE_FILE="${BATS_TEST_TMPDIR}/mc-idle-counter"
    export PENDING_STOP_FILE="${BATS_TEST_TMPDIR}/mc-idle-stopping"
    export BOOT_FAIL_FILE="${BATS_TEST_TMPDIR}/mc-boot-fail-counter"
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
    export MOCK_RCON_OUT="There are 0 of a max of 20 players online: "
    : >"$CALL_LOG"

    cat <<'EOF' >"${MOCK_BIN}/docker"
#!/usr/bin/env bash
echo "docker $*" >>"$CALL_LOG"
if [ "$1" = "ps" ]; then
    echo "abc12345"
elif [ "$1" = "exec" ] && [ "$2" = "mc-server" ] && [ "$3" = "rcon-cli" ] && [ "$4" = "list" ]; then
    echo "$MOCK_RCON_OUT"
fi
exit 0
EOF

    cat <<'EOF' >"${MOCK_BIN}/curl"
#!/usr/bin/env bash
echo "curl $*" >>"$CALL_LOG"
exit "${MOCK_CURL_EXIT:-0}"
EOF

    cat <<'EOF' >"${MOCK_BIN}/sleep"
#!/usr/bin/env bash
exit 0
EOF

    cat <<'EOF' >"${MOCK_BIN}/systemctl"
#!/usr/bin/env bash
echo "systemctl $*" >>"$CALL_LOG"
exit 0
EOF

    chmod +x "${MOCK_BIN}/docker" "${MOCK_BIN}/curl" "${MOCK_BIN}/sleep" "${MOCK_BIN}/systemctl"
}

@test "idle-watchdog exits immediately when ALWAYS_ON=true" {
    ALWAYS_ON="true" run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$STATE_FILE" ]
    [ ! -s "$CALL_LOG" ]
}

@test "idle-watchdog resets counter to 0 when players are online" {
    echo "4" >"$STATE_FILE"
    export MOCK_RCON_OUT="There are 2 of a max of 20 players online: Alex, Steve"

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "0" ]
}

@test "idle-watchdog increments idle counter when 0 players are online below threshold" {
    echo "1" >"$STATE_FILE"
    IDLE_TIMEOUT_MINUTES="5" run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE_FILE")" = "2" ]
    [ ! -f "$PENDING_STOP_FILE" ]
}

@test "idle-watchdog triggers backup, stops containers, and dispatches workflow at threshold" {
    echo "2" >"$STATE_FILE"
    export IDLE_TIMEOUT_MINUTES="3"
    export GITHUB_REPOSITORY="example-owner/example-repo"
    export GITHUB_PAT="ghp_test_token"

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]

    grep -q "docker exec mc-backup backup-now" "$CALL_LOG"
    grep -q "docker stop mc-backup" "$CALL_LOG"
    grep -q "docker stop mc-server" "$CALL_LOG"
    grep -q "curl.*server-stop.yml/dispatches" "$CALL_LOG"
    grep -q "systemctl poweroff" "$CALL_LOG"
    [ ! -f "$STATE_FILE" ]
    [ ! -f "$PENDING_STOP_FILE" ]
}

@test "idle-watchdog retries workflow dispatch on next tick when PENDING_STOP_FILE exists" {
    touch "$PENDING_STOP_FILE"
    export GITHUB_REPOSITORY="example-owner/example-repo"
    export GITHUB_PAT="ghp_test_token"

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "curl.*server-stop.yml/dispatches" "$CALL_LOG"
    ! grep -q "docker exec" "$CALL_LOG"
    [ ! -f "$PENDING_STOP_FILE" ]
}

@test "idle-watchdog increments boot fail counter when RCON is unresponsive below threshold" {
    export MOCK_RCON_OUT=""
    export BOOT_TIMEOUT_MINUTES="5"

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$BOOT_FAIL_FILE")" = "1" ]
    [ ! -f "$PENDING_STOP_FILE" ]
}

@test "idle-watchdog stops containers and triggers shutdown when boot fail threshold is reached" {
    echo "2" >"$BOOT_FAIL_FILE"
    export MOCK_RCON_OUT=""
    export BOOT_TIMEOUT_MINUTES="3"
    export GITHUB_REPOSITORY="example-owner/example-repo"
    export GITHUB_PAT="ghp_test_token"

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "docker stop mc-backup" "$CALL_LOG"
    grep -q "docker stop mc-server" "$CALL_LOG"
    grep -q "curl.*server-stop.yml/dispatches" "$CALL_LOG"
    grep -q "systemctl poweroff" "$CALL_LOG"
}

@test "idle-watchdog clears boot fail counter once RCON becomes responsive" {
    echo "3" >"$BOOT_FAIL_FILE"
    export MOCK_RCON_OUT="There are 0 of a max of 20 players online: "

    run "$WATCHDOG_SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -f "$BOOT_FAIL_FILE" ]
}
