#!/usr/bin/env bats
# tests/unit/template.bats — test sed substitution of placeholders

load '../lib/helpers'

@test "substitution replaces all placeholders in desktop user-data" {
    local PASS_HASH='$6$rounds=4096$testhash'
    local PERSONALIZATION_USERNAME="testuser"
    local PERSONALIZATION_FULLNAME="Test User"
    local VMCTL_KEY_B64=$(echo "testkey" | base64)
    local DEFAULT_REF="v1.0"

    sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
        -e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g" \
        -e "s|__PERSONALIZATION_USERNAME__|${PERSONALIZATION_USERNAME}|g" \
        -e "s|__PERSONALIZATION_FULLNAME__|${PERSONALIZATION_FULLNAME}|g" \
        -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
        "${PROJECT_ROOT}/desktop/user-data/user-data" > /tmp/test-userdata

    assert_not_contains "$(cat /tmp/test-userdata)" '__PERSONALIZATION_USERNAME__'
    assert_not_contains "$(cat /tmp/test-userdata)" '__PERSONALIZATION_FULLNAME__'
    assert_not_contains "$(cat /tmp/test-userdata)" 'CHANGE_ME_HASHED'
    assert_not_contains "$(cat /tmp/test-userdata)" '__GITHUB_REF__'
    assert_contains "$(cat /tmp/test-userdata)" 'testuser'
    assert_contains "$(cat /tmp/test-userdata)" 'Test User'
    assert_contains "$(cat /tmp/test-userdata)" 'v1.0'

    rm -f /tmp/test-userdata
}

@test "substitution replaces all placeholders in llm user-data" {
    local PASS_HASH='$6$rounds=4096$testhash'
    local PERSONALIZATION_USERNAME="testuser"
    local PERSONALIZATION_FULLNAME="Test User"
    local DEFAULT_REF="v1.0"

    sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
        -e "s|__VMCTL_PRIV_B64__||g" \
        -e "s|__PERSONALIZATION_USERNAME__|${PERSONALIZATION_USERNAME}|g" \
        -e "s|__PERSONALIZATION_FULLNAME__|${PERSONALIZATION_FULLNAME}|g" \
        -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
        "${PROJECT_ROOT}/llm/user-data/user-data" > /tmp/test-llm-data

    assert_not_contains "$(cat /tmp/test-llm-data)" '__PERSONALIZATION_USERNAME__'
    assert_not_contains "$(cat /tmp/test-llm-data)" 'CHANGE_ME_HASHED'
    assert_contains "$(cat /tmp/test-llm-data)" 'testuser'
    assert_contains "$(cat /tmp/test-llm-data)" 'v1.0'

    rm -f /tmp/test-llm-data
}

@test "answer-host.toml substitution replaces __GITHUB_REF__" {
    local DEFAULT_REF="abc123"
    sed -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
        "${PROJECT_ROOT}/provision/host/answer-host.toml" > /tmp/test-answer

    assert_not_contains "$(cat /tmp/test-answer)" '__GITHUB_REF__'
    assert_contains "$(cat /tmp/test-answer)" 'abc123'

    rm -f /tmp/test-answer
}
