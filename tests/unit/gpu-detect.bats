#!/usr/bin/env bats
# tests/unit/gpu-detect.bats — partitioning the accepted passthrough set.
#
# frag/10 decides which devices may be passed through; frag/30's
# partition_passthrough_devices splits that set by role (integrated GPU to the
# desktop, discrete NVIDIA GPUs to the LLM guest) without adding a device of
# its own. `lspci` is mocked; the function runs for real and the resulting
# device sets are observed.

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    # The fragment's log() writes under ${ROOT}/var/log, which does not exist
    # here; capture the messages instead so warnings are observable.
    log() { printf '%s\n' "$*"; }
    LIST="${BATS_TMPDIR}/passthrough-devices"
}

teardown() {
    cleanup_mocks
}

# $1... = <bdf>=<vendor:device> pairs answering `lspci -n -s <bdf>`
lspci_mock() {
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/lspci-single-gpu.txt"
    export LSPCI_TABLE="$*"
}

write_list() {
    printf '%s\n' "$@" > "$LIST"
}

@test "an iGPU-only set goes to the desktop, nothing to the LLM guest" {
    lspci_mock "00:02.0=8086:5912"
    write_list "0000:00:02.0"
    partition_passthrough_devices "$LIST"
    [ "$IGPU_IDS" = "0000:00:02.0" ]
    [ -z "$DGPU_IDS" ]
}

@test "a mixed set is partitioned by vendor" {
    # The branch the end-to-end suite cannot reach: its fixture host excludes
    # the dGPUs, so the LLM guest gets nothing there. Here an accepted dGPU
    # and its audio function go to the LLM guest while the iGPU goes to the
    # desktop.
    lspci_mock "00:02.0=8086:5912" "01:00.0=10de:1b80" "01:00.1=10de:10f0"
    write_list "0000:00:02.0" "0000:01:00.0" "0000:01:00.1"
    partition_passthrough_devices "$LIST"
    [ "$IGPU_IDS" = "0000:00:02.0" ]
    [ "$DGPU_IDS" = "0000:01:00.0,0000:01:00.1" ]
}

@test "a device of unrecognized vendor is left to the host with a warning" {
    lspci_mock "00:02.0=8086:5912" "04:00.0=1af4:1050"
    write_list "0000:00:02.0" "0000:04:00.0"
    # Called directly, not under `run`: the device sets are globals, and a
    # subshell would discard them.
    partition_passthrough_devices "$LIST" >"$BATS_TMPDIR/out" 2>&1
    [ "$IGPU_IDS" = "0000:00:02.0" ]
    [ -z "$DGPU_IDS" ]
    run grep -q "unrecognized vendor '1af4'" "$BATS_TMPDIR/out"
}

@test "a missing device list aborts instead of attaching nothing" {
    # An empty --hostpci is a silent downgrade: the guest is created, boots,
    # and has no GPU, and nothing in the log explains it.
    run partition_passthrough_devices "${BATS_TMPDIR}/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"frag/10 did not run"* ]]
}

@test "an empty device list aborts instead of attaching nothing" {
    : > "$LIST"
    run partition_passthrough_devices "$LIST"
    [ "$status" -ne 0 ]
    [[ "$output" == *"accepted nothing"* ]]
}
