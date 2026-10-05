#!/usr/bin/env bats
# tests/unit/frag30-guest-create.bats — guest creation prerequisites in frag/30
#
# All three guests are created in one `set -euo pipefail` main(). A single
# failing `qm create` therefore aborts the fragment and leaves the host with
# zero VMs — the observed symptom — and the only clue in the log is a bare `qm`
# error several minutes after the run started, after two ISO downloads.
#
# The two prerequisites `qm create` actually validates are the bridge named on
# --net0 and the storage named on --scsi0. The install answer configures
# networking as `source = "from-dhcp"`, which yields an address but not
# necessarily a Linux bridge, so the missing-bridge case is the likely one.
#
# These are behavioural: `ip` and `pvesm` are mocked, so the preflight runs for
# real and its exit status is observed.

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    # The fragment's log() appends under ${ROOT}/var/log (empty ROOT here, so the
    # real /var/log path, which does not exist in this environment) — and under
    # `set -euo pipefail` a failed printf makes every call to it abort, which
    # would look like the preflight itself failing. Capture the messages instead
    # so the exit status and the diagnostics are both observable.
    log() { printf '%s\n' "$*"; }
}

teardown() {
    rm -rf "${SWORK:-/nonexistent-serial-scratch}"
    cleanup_mocks
}

# A host with the named bridge and storage present.
host_with_prereqs() {
    install_mock ip "mock-ip-link-exists.sh"
    install_mock pvesm "mock-pvesm-storage-ok.sh"
}

# A host missing only the bridge, which is what `from-dhcp` alone produces.
host_without_bridge() {
    install_mock ip "mock-ip-link-missing.sh"
    install_mock pvesm "mock-pvesm-storage-ok.sh"
}

host_without_storage() {
    install_mock ip "mock-ip-link-exists.sh"
    install_mock pvesm "mock-pvesm-storage-missing.sh"
}

@test "preflight passes on a host that has the bridge and storage" {
    host_with_prereqs
    run preflight_guest_prerequisites "vmbr0" "local-lvm"
    [ "$status" -eq 0 ]
}

@test "preflight fails when the bridge does not exist" {
    host_without_bridge
    run preflight_guest_prerequisites "vmbr0" "local-lvm"
    [ "$status" -ne 0 ]
}

@test "the missing bridge is named, not just reported as a failure" {
    # An operator who only sees "ERROR: line 149" has nothing to act on. The
    # bridge name and the fact that qm create will reject the guests is the
    # difference between a diagnosable and an opaque failure.
    host_without_bridge
    run preflight_guest_prerequisites "vmbr0" "local-lvm"
    [[ "$output" == *"vmbr0"* ]]
}

@test "preflight fails when the storage does not exist" {
    host_without_storage
    run preflight_guest_prerequisites "vmbr0" "local-lvm"
    [ "$status" -ne 0 ]
    [[ "$output" == *"local-lvm"* ]]
}

@test "preflight reports every missing prerequisite, not just the first" {
    # Reporting them one at a time costs a full run each time.
    host_without_bridge
    install_mock pvesm "mock-pvesm-storage-missing.sh"
    run preflight_guest_prerequisites "vmbr0" "local-lvm"
    [[ "$output" == *"vmbr0"* ]]
    [[ "$output" == *"local-lvm"* ]]
}

@test "core allocations are capped at the node's per-VM maximum" {
    # PVE 9 refuses a VM whose vCPU count exceeds the node's per-VM maximum,
    # which tracks the host's visible cores: 6 cores on a 4-core host fails
    # the create with "MAX 4 vcpus allowed per VM on this node".
    CPU_CORES=4
    run cap_vm_cores 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"capping"* ]]
    [ "$(printf '%s\n' "$output" | tail -1)" = "4" ]
}

@test "core allocations within the maximum pass through unchanged" {
    CPU_CORES=8
    run cap_vm_cores 6
    [ "$status" -eq 0 ]
    [ "$output" = "6" ]
}

# --- os_esp: the install gate's bootloader check ---
#
# Stopped alone is end-of-run, not end-of-success, so the gate requires an
# EFI partition on the OS disk before detaching the installer. Probed per
# device (blkid cache misses fresh tables; scan output spellings don't
# survive), matched by content, candidates overridable via VM_DISK_DEVS.

mock_blkid() {
    # $1 = what the probe prints (empty for a disk with no ESP). Payload goes
    # through a file because quoting blkid output inline nests double quotes
    # inside double quotes and silently mangles the mock.
    printf '%s\n' "$1" > "${BATS_TMPDIR}/blkid-out"
    printf '#!/bin/bash\ncat "%s/blkid-out"\n' "$BATS_TMPDIR" \
        > "${FIXTURES_DIR}/mock-bin/blkid"
    chmod +x "${FIXTURES_DIR}/mock-bin/blkid"
}

@test "os_esp finds the bootloader signature on a partitioned disk" {
    touch "${BATS_TMPDIR}/disk-101"
    VM_DISK_DEVS="${BATS_TMPDIR}/disk-101" export VM_DISK_DEVS
    mock_blkid '/dev/pve/vm-101-disk-1p1: PARTLABEL="EFI System Partition" PARTTYPE="c12a4738-f02b-4b93-8fd5-043ef0e62c58"'
    run os_esp 101
    [ "$status" -eq 0 ]
    unset VM_DISK_DEVS
}

@test "os_esp fails cleanly with no ESP anywhere" {
    touch "${BATS_TMPDIR}/disk-102"
    VM_DISK_DEVS="${BATS_TMPDIR}/disk-102" export VM_DISK_DEVS
    mock_blkid ''
    run os_esp 102
    [ "$status" -ne 0 ]
    unset VM_DISK_DEVS
}

@test "os_esp fails cleanly with no candidate devices at all" {
    VM_DISK_DEVS="${BATS_TMPDIR}/does-not-exist" export VM_DISK_DEVS
    mock_blkid '/dev/x: PARTTYPE="c12a4738-f02b-4b93-8fd5-043ef0e62c58"'
    run os_esp 103
    [ "$status" -ne 0 ]
    unset VM_DISK_DEVS
}

# --- start/stop_serial_capture: install serial to a host log ---
#
# socat on a not-yet-existing socket dies instantly, so the start is a retry
# loop (stale readers killed first); the stop kills the loop and any
# connected stream. Time-only env seams: SERIAL_RETRY_MAX/INTERVAL.

serial_capture_fixture() {
    # $1 = socat failures before success. Own scratch dir: this file's
    # setup provides none (its tests never needed one). Re-sources the
    # fragment AFTER exporting PVE_ROOT: ROOT snapshots it at source time,
    # so sourcing first (as the shared setup does) would pin the log and
    # capture paths to the wrong root.
    SWORK="$(mktemp -d)"
    export PVE_ROOT="$SWORK"
    mkdir -p "${SWORK}/var/log"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    log() { printf '%s\n' "$*"; }
    export MOCK_JOURNAL="$SWORK" MOCK_COUNT="${SWORK}/socat-count"
    printf '%s\n' "$1" > "$MOCK_COUNT"
    install_mock socat "mock-socat.sh"
    install_mock pkill "mock-pkill.sh"
    export SERIAL_RETRY_MAX=4 SERIAL_RETRY_INTERVAL=1
    SERIAL_CAP_PID=""
}

@test "capture starts on first connect and stops cleanly" {
    serial_capture_fixture 0
    start_serial_capture 101 >"${SWORK}/start.out" 2>&1
    [ "$?" -eq 0 ]
    [ -n "$SERIAL_CAP_PID" ]
    wait "$SERIAL_CAP_PID"
    run grep -c "^socat " "${SWORK}/socat-journal"
    [ "$output" = "1" ]
    run grep -q "qemu-server/101.serial" "${SWORK}/socat-journal"
    [ "$status" -eq 0 ]
    stop_serial_capture 101
    [ -z "$SERIAL_CAP_PID" ]
    unset PVE_ROOT MOCK_JOURNAL MOCK_COUNT SERIAL_RETRY_MAX SERIAL_RETRY_INTERVAL
}

@test "capture retries a missing socket then connects" {
    serial_capture_fixture 2
    start_serial_capture 101 >"${SWORK}/start.out" 2>&1
    [ "$?" -eq 0 ]
    wait "$SERIAL_CAP_PID"
    run grep -c "^socat " "${SWORK}/socat-journal"
    [ "$output" = "3" ]
    stop_serial_capture 101
    unset PVE_ROOT MOCK_JOURNAL MOCK_COUNT SERIAL_RETRY_MAX SERIAL_RETRY_INTERVAL
}

@test "capture gives up loudly after the cap, never fatally" {
    serial_capture_fixture 99
    export SERIAL_RETRY_MAX=2
    start_serial_capture 101 >"${SWORK}/start.out" 2>&1
    [ "$?" -eq 0 ]
    wait "$SERIAL_CAP_PID"
    run grep -c "^socat " "${SWORK}/socat-journal"
    [ "$output" = "2" ]
    assert_file_contains "${SWORK}/start.out" "never connected"
    stop_serial_capture 101
    unset PVE_ROOT MOCK_JOURNAL MOCK_COUNT SERIAL_RETRY_MAX SERIAL_RETRY_INTERVAL
}

@test "capture without socat warns once and proceeds" {
    SWORK="$(mktemp -d)"
    export PVE_ROOT="$SWORK"
    mkdir -p "${SWORK}/var/log"
    SERIAL_CAP_PID=""
    PATH="${FIXTURES_DIR}/mock-bin" run start_serial_capture 101
    [ "$status" -eq 0 ]
    assert_contains "$output" "socat unavailable"
    [ -z "$SERIAL_CAP_PID" ]
    unset PVE_ROOT
}
