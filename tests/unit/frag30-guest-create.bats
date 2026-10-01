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
