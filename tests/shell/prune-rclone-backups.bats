#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    PRUNE_SCRIPT="${REPO_ROOT}/iac/files/scripts/prune-rclone-backups.sh"

    MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="${MOCK_BIN}:${PATH}"

    export RCLONE_CALLS="${BATS_TEST_TMPDIR}/rclone_calls.log"
    export MOCK_LSF_OUTPUT="${BATS_TEST_TMPDIR}/lsf_output.txt"
    : >"$RCLONE_CALLS"
    : >"$MOCK_LSF_OUTPUT"

    cat <<'EOF' >"${MOCK_BIN}/rclone"
#!/usr/bin/env bash
echo "$*" >>"$RCLONE_CALLS"
if [ "$1" = "lsf" ]; then
    cat "$MOCK_LSF_OUTPUT"
fi
exit 0
EOF
    chmod +x "${MOCK_BIN}/rclone"

    export RCLONE_REMOTE="backup"
    export RCLONE_DEST_DIR="my-bucket/minecraft-backups"
    export BACKUP_RETENTION_COUNT="3"
    export BACKUP_NAME="world"
}

@test "prune-rclone-backups skips pruning when backup_status ($1) is non-zero" {
    cat <<'EOF' >"$MOCK_LSF_OUTPUT"
world-20261101-120000.tar.zst
world-20261102-120000.tar.zst
world-20261103-120000.tar.zst
world-20261104-120000.tar.zst
EOF

    run "$PRUNE_SCRIPT" 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping remote rclone prune"* ]]
    [ ! -s "$RCLONE_CALLS" ]
}

@test "prune-rclone-backups deletes only backups older than BACKUP_RETENTION_COUNT" {
    cat <<'EOF' >"$MOCK_LSF_OUTPUT"
world-20261101-120000.tar.zst
world-20261102-120000.tar.zst
world-20261103-120000.tar.zst
world-20261104-120000.tar.zst
world-20261105-120000.tar.zst
unrelated-file.txt
EOF

    run "$PRUNE_SCRIPT" 0
    [ "$status" -eq 0 ]

    grep -q "deletefile backup:my-bucket/minecraft-backups/world-20261102-120000.tar.zst" "$RCLONE_CALLS"
    grep -q "deletefile backup:my-bucket/minecraft-backups/world-20261101-120000.tar.zst" "$RCLONE_CALLS"
    ! grep -q "world-20261105-120000.tar.zst" "$RCLONE_CALLS"
    ! grep -q "world-20261104-120000.tar.zst" "$RCLONE_CALLS"
    ! grep -q "world-20261103-120000.tar.zst" "$RCLONE_CALLS"
    ! grep -q "unrelated-file.txt" "$RCLONE_CALLS"
}

@test "prune-rclone-backups does not delete when backup count is within retention limit" {
    cat <<'EOF' >"$MOCK_LSF_OUTPUT"
world-20261104-120000.tar.zst
world-20261105-120000.tar.zst
EOF

    run "$PRUNE_SCRIPT" 0
    [ "$status" -eq 0 ]
    ! grep -q "deletefile" "$RCLONE_CALLS"
}
