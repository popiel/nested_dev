#!/usr/bin/env bats
# tests/unit/nested-keys-status.bats — dev/tools/nested keys-status, executed.
#
# The operator-facing credential check: it must look in keys/ — the same
# gitignored directory the build reads — for both password hashes, so a check
# that looks elsewhere reports working credentials as missing and tells the
# operator to create a second, wrong copy that no build ever reads.
#
# Executed rather than grepped: NESTED_DEV derives from HOME, so pointing HOME
# at a fixture tree runs the verb against fixture credentials, with only the
# docker preamble stubbed out.

load '../lib/helpers'

NESTED="${PROJECT_ROOT}/dev/tools/nested"

setup() {
    WORK="${BATS_TMPDIR}/nested"
    rm -rf "$WORK"
    mkdir -p "$WORK/home/work/nested_dev/.git" "$WORK/home/work/nested_dev/keys" \
        "$WORK/bin"
    printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/docker"
    chmod +x "$WORK/bin/docker"
}

teardown() {
    rm -rf "$WORK"
}

run_keys_status() {
    env HOME="$WORK/home" PATH="$WORK/bin:$PATH" bash "$NESTED" keys-status
}

@test "missing hashes are reported as missing, in keys/" {
    run run_keys_status
    [ "$status" -eq 0 ]
    assert_contains "$output" "keys/personalization-password-hash: MISSING"
    assert_contains "$output" "keys/root-password-hash: MISSING"
    assert_not_contains "$output" "secrets/"
}

@test "present hashes are reported as present" {
    printf 'x' > "$WORK/home/work/nested_dev/keys/personalization-password-hash"
    printf 'x' > "$WORK/home/work/nested_dev/keys/root-password-hash"
    run run_keys_status
    [ "$status" -eq 0 ]
    assert_contains "$output" "keys/personalization-password-hash: present"
    assert_contains "$output" "keys/root-password-hash: present"
}
