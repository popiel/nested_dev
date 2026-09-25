#!/usr/bin/env bats
# tests/unit/build-iso.bats — test build-iso pure functions

load '../lib/helpers'

setup() {
    source "${PROJECT_ROOT}/provision/ubuntu-release.conf"
    source "${PROJECT_ROOT}/provision/host/build-iso.sh"
}

@test "ubuntu-release.conf sets UBUNTU_VERSION" {
    [ "$UBUNTU_VERSION" = "26.04" ]
}

@test "ubuntu-release.conf sets UBUNTU_BASE_URL" {
    [ "$UBUNTU_BASE_URL" = "https://releases.ubuntu.com/26.04" ]
}

@test "sed_escape escapes backslash" {
    run sed_escape 'foo\bar'
    [ "$output" = 'foo\\bar' ]
}

@test "sed_escape escapes dollar signs" {
    run sed_escape 'abc$123'
    [ "$output" = 'abc\$123' ]
}

@test "sed_escape escapes pipe characters" {
    run sed_escape 'foo|bar'
    [ "$output" = 'foo\|bar' ]
}

@test "sed_escape escapes ampersand" {
    run sed_escape 'foo&bar'
    [ "$output" = 'foo\&bar' ]
}

@test "sed_escape handles yescrypt hash" {
    local hash='$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW.gJAqoB0k7emCAu.0N4o.bCemMC'
    run sed_escape "$hash"
    assert_contains "$output" '\$y\$j9T'
    assert_contains "$output" '\$6Y5z'
}

@test "detect_target_disk function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'detect_target_disk()'
}

@test "generate_answer_file function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'generate_answer_file()'
}

@test "run_prepare_iso function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'run_prepare_iso()'
}

@test "download_iso function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'download_iso()'
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
