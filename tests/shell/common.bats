#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=scripts/lib/common.sh
    source "${REPO_ROOT}/scripts/lib/common.sh"

    SETTINGS_FILE="${BATS_TEST_TMPDIR}/settings.yaml"
    cat <<'EOF' >"$SETTINGS_FILE"
server:
  location: "fsn1" # primary region
  server_type: 'cax21'
  idle_timeout_minutes: 15

minecraft:
  motd: "Welcome to #1 Server!"
  whitelist:
    - "PlayerOne" # admin
    - 'PlayerTwo'
  ops: ["OpOne", 'OpTwo']
  plugins: []
EOF

    DECRYPTED="$(cat <<'EOF'
hcloud_token: "hc_secret_#123_abc" # inline comment
rcon_password: 'single_quoted_#secret'
auth_password: ""
short_val: "ab"
EOF
)"
}

@test "get_secret preserves # inside secret values and strips inline comments" {
    run get_secret "hcloud_token"
    [ "$status" -eq 0 ]
    [ "$output" = "hc_secret_#123_abc" ]
}

@test "get_secret strips surrounding single quotes" {
    run get_secret "rcon_password"
    [ "$status" -eq 0 ]
    [ "$output" = "single_quoted_#secret" ]
}

@test "get_secret returns empty string for empty secret" {
    run get_secret "auth_password"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "get_setting parses double-quoted, single-quoted, and unquoted scalars in target section" {
    run get_setting "server" "location"
    [ "$status" -eq 0 ]
    [ "$output" = "fsn1" ]

    run get_setting "server" "server_type"
    [ "$status" -eq 0 ]
    [ "$output" = "cax21" ]

    run get_setting "server" "idle_timeout_minutes"
    [ "$status" -eq 0 ]
    [ "$output" = "15" ]
}

@test "get_setting preserves # inside quoted MOTD string" {
    run get_setting "minecraft" "motd"
    [ "$status" -eq 0 ]
    [ "$output" = "Welcome to #1 Server!" ]
}

@test "get_setting_list parses multiline YAML lists and strips comments and quotes" {
    run get_setting_list "minecraft" "whitelist"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "PlayerOne" ]
    [ "${lines[1]}" = "PlayerTwo" ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "get_setting_list parses inline bracketed YAML lists and empty lists" {
    run get_setting_list "minecraft" "ops"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "OpOne" ]
    [ "${lines[1]}" = "OpTwo" ]
    [ "${#lines[@]}" -eq 2 ]

    run get_setting_list "minecraft" "plugins"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
