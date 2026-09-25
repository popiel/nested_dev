#!/usr/bin/env bats
# tests/unit/build-iso.bats — test ISO filename/URL construction

load '../lib/helpers'

setup() {
    source "${PROJECT_ROOT}/provision/ubuntu-release.conf"
}

@test "ubuntu-release.conf sets UBUNTU_VERSION" {
    [ "$UBUNTU_VERSION" = "26.04" ]
}

@test "ubuntu-release.conf sets UBUNTU_BASE_URL" {
    [ "$UBUNTU_BASE_URL" = "https://releases.ubuntu.com/26.04" ]
}

@test "detect_target_disk function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'detect_target_disk()'
}

@test "generate_answer_file function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'generate_answer_file()'
}

@test "build-iso.sh has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'BASH_SOURCE\[0\].*==.*\$0'
}

@test "frag/30 has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'BASH_SOURCE\[0\].*==.*\$0'
}

@test "frag/10 has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" 'BASH_SOURCE\[0\].*==.*\$0'
}
