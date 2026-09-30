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
    # The fragment's log() appends to the hardcoded /var/log/pve-firstboot.log,
    # which does not exist here — and under `set -euo pipefail` a failed
    # printf makes every call to it abort, which would look like the preflight
    # itself failing. Capture the messages instead so the exit status and the
    # diagnostics are both observable.
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

@test "the preflight does not guess which NIC to bridge" {
    # Taking the first non-loopback interface automatically is the same class of
    # mistake as the disk probe R-01.4.1 prohibits: it can pick the host's only
    # network path and take the host off the network. A missing bridge is
    # reported and left to the operator.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh")
    assert_not_contains "$src" 'ip route get 1.1.1.1'
    assert_not_contains "$src" "ip link show | awk -F': ' 'NR==3"
    assert_not_contains "$src" 'nmcli con add type bridge'
}

@test "the guests use the same bridge and storage the preflight checked" {
    # Otherwise the preflight can pass against a bridge no guest uses, which is
    # the exact silent-failure it was added to prevent: the check would be
    # correct about `vmbr0` while every guest still asked for something else.
    local frag="${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"

    # The bridge and storage appear exactly once each, as declarations...
    run grep -c 'GUEST_BRIDGE="vmbr0"' "$frag"
    [ "$output" -eq 1 ]
    run grep -c 'GUEST_STORAGE="local-lvm"' "$frag"
    [ "$output" -eq 1 ]

    # ...and no guest references a literal name directly.
    run grep -n 'bridge=vmbr0' "$frag"
    [ -z "$output" ] || {
        echo "a guest still hardcodes the bridge:" >&2
        echo "$output" >&2
        return 1
    }
    run grep -n -- '--scsi[01] local-lvm:' "$frag"
    [ -z "$output" ] || {
        echo "a guest still hardcodes the storage:" >&2
        echo "$output" >&2
        return 1
    }

    # All three guests bridge through the one declaration.
    run grep -c 'bridge=${GUEST_BRIDGE}' "$frag"
    [ "$output" -eq 3 ]
}

@test "the preflight runs before the ISO downloads" {
    # The downloads take minutes. Checking afterwards means the operator waits
    # out both of them before being told the host cannot create a guest.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh")
    local pf_line dl_line
    pf_line=$(grep -n '^[^#]*preflight_guest_prerequisites "\$GUEST_BRIDGE"' <<< "$src" | cut -d: -f1)
    dl_line=$(grep -n '^[^#]*download_iso "\${UBUNTU_BASE_URL}' <<< "$src" | head -1 | cut -d: -f1)
    [ -n "$pf_line" ] || { echo "main() never calls the preflight" >&2; return 1; }
    [ -n "$dl_line" ] || { echo "the ISO download line moved" >&2; return 1; }
    [ "$pf_line" -lt "$dl_line" ] || {
        echo "preflight at $pf_line runs after the download at $dl_line" >&2
        return 1
    }
}

@test "detect_gpu_pci compares IOMMU groups by entry, not by regular file" {
    # Same defect as in frag/10: sysfs publishes group members as symlinks to
    # device directories, so `find -type f` returns nothing for both the GPU and
    # the audio group. diff then compares "" with "", calls the two groups
    # identical, and the audio companion is never added to the passthrough set.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh")
    run grep -c 'find "\$audio_group" -maxdepth 1 -type f' \
        "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    [ "$output" -eq 0 ] || {
        echo "detect_gpu_pci still matches regular files only" >&2
        return 1
    }
    assert_contains "$src" 'find "$audio_group" -mindepth 1 -maxdepth 1 -printf'
    assert_contains "$src" 'find "$gpu_group" -mindepth 1 -maxdepth 1 -printf'
}
