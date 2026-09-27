#!/usr/bin/env bats
# tests/unit/frag10-iommu.bats — test CPU vendor detection + IOMMU R4 from frag/10

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
}

teardown() {
    cleanup_mocks
}

# --- CPU vendor ---

@test "detect_cpu_vendor lowercases the lscpu vendor id" {
    create_mock "lscpu" 'echo "Vendor ID:                        GenuineIntel"'
    run detect_cpu_vendor
    [ "$output" = "genuineintel" ]
}

@test "detect_cpu_vendor returns empty when lscpu reports no vendor" {
    create_mock "lscpu" 'echo "Architecture:  x86_64"'
    run detect_cpu_vendor
    [ -z "$output" ]
}

# The kernel parameter differs per vendor, and a mismatch is silent: IOMMU
# simply stays off and the GPU group is never separable.
@test "iommu_flag_for_vendor maps each supported vendor" {
    create_mock "lscpu" 'echo "Vendor ID:  GenuineIntel"'
    run iommu_flag_for_vendor "$(detect_cpu_vendor)"
    [ "$output" = "intel_iommu=on" ]

    create_mock "lscpu" 'echo "Vendor ID:  AuthenticAMD"'
    run iommu_flag_for_vendor "$(detect_cpu_vendor)"
    [ "$output" = "amd_iommu=on" ]
}

@test "iommu_flag_for_vendor fails for a vendor with no known flag" {
    # Returning a flag for an unknown CPU would boot the host with IOMMU
    # silently disabled; the caller has to be able to abort.
    run iommu_flag_for_vendor "someothervendor"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- Audio companion ---

@test "find_audio_companion returns BDF for audio device" {
    create_mock "lspci" 'echo "01:00.0 VGA compatible controller: NVIDIA ..."
echo "01:00.1 Audio device: NVIDIA ..."'
    run find_audio_companion "01:00.0"
    [ "$output" = "01:00.1" ]
}

@test "find_audio_companion returns empty when no audio" {
    create_mock "lspci" 'echo "01:00.0 VGA compatible controller: NVIDIA ..."'
    run find_audio_companion "01:00.0"
    [ -z "$output" ]
}

# --- collect_gpu_ids: what actually reaches VFIO ---

@test "collect_gpu_ids excludes the virtio GPU" {
    # A PVE host always has a virtio VGA controller. Handing it to VFIO takes
    # away the console the operator is installing from, and on a headless host
    # leaves nothing to debug with.
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/lspci-multi-gpu.txt"
    export LSPCI_TABLE="01:00.0=10de:2204 01:00.1=10de:1aef 00:02.0=8086:9bc5 04:00.0=1af4:1050"
    local ids=() names=()
    run bash -c 'source "'"${PROJECT_ROOT}"'/provision/host/frag/10-gpu-passthrough.sh"
        log() { :; }
        declare -a ids=() names=()
        collect_gpu_ids ids names
        printf "%s\n" "${ids[@]}"'
    assert_contains "$output" "10de:2204"
    assert_not_contains "$output" "1af4:1050"
}

@test "collect_gpu_ids returns an empty set on a host with only a virtio GPU" {
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/lspci-no-gpu.txt"
    export LSPCI_TABLE="04:00.0=1af4:1050"
    run bash -c 'source "'"${PROJECT_ROOT}"'/provision/host/frag/10-gpu-passthrough.sh"
        log() { :; }
        declare -a ids=() names=()
        collect_gpu_ids ids names
        printf "%d\n" "${#ids[@]}"'
    [ "$output" = "0" ]
}

# --- IOMMU R4: a group with more than one device is not separable ---
#
# These previously created a temp dir and counted its own files, without ever
# calling the function they were named after, so the rule they claimed to cover
# had no coverage at all. iommu_group_device_count takes the directory as an
# argument precisely so the rule can be exercised here.

iommu_group() {
    # $1 = temp dir, rest = device BDFs placed in one group
    local dir="$1"; shift
    local bdf
    mkdir -p "${dir}/devices"
    for bdf in "$@"; do
        : > "${dir}/devices/${bdf}"
    done
}

@test "iommu_group_device_count counts the devices in a group" {
    local tmpdir="${BATS_TMPDIR}/iommu"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 01:00.0
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "1" ]

    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 01:00.0 01:00.1
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "2" ]
}

@test "iommu_group_device_count reports zero for a group that does not exist" {
    # A GPU with no IOMMU group directory at all is not a separable-group
    # failure; main() skips those before consulting the rule.
    run iommu_group_device_count "${BATS_TMPDIR}/no-such-group/devices"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "R4: a single-device group is separable" {
    local tmpdir="${BATS_TMPDIR}/iommu-single"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 01:00.0
    run iommu_group_is_separable "${tmpdir}/devices"
    [ "$status" -eq 0 ]
}

@test "R4: a shared group with two devices is not separable" {
    # GPU plus its HDMI audio function in one group is the common case this
    # rule exists to catch: passing the group through hands the host the audio
    # function too and the GPU stops working.
    local tmpdir="${BATS_TMPDIR}/iommu-shared"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 01:00.0 01:00.1
    run iommu_group_is_separable "${tmpdir}/devices"
    [ "$status" -ne 0 ]
}

@test "R4: a group with three devices is not separable either" {
    local tmpdir="${BATS_TMPDIR}/iommu-triple"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 01:00.0 01:00.1 01:00.2
    run iommu_group_is_separable "${tmpdir}/devices"
    [ "$status" -ne 0 ]
}

@test "check_iommu_group_separable maps a BDF to its sysfs group directory" {
    # The one part of check_iommu_group_separable that cannot be redirected to
    # a temp dir: the BDF-to-path mapping. Getting it wrong would check a
    # directory that never exists, which counts 0 devices and always passes.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    assert_contains "$src" '"/sys/bus/pci/devices/0000:${pci_addr}/iommu_group/devices"'
}

@test "main enforces the R4 rule through check_iommu_group_separable" {
    # Otherwise main() is free to re-derive the group size and drift from the
    # rule the tests cover, which is what it used to do.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    assert_contains "$src" 'if ! check_iommu_group_separable "$PCI_ADDR"; then'
    assert_contains "$src" 'if ! check_iommu_group_separable "$AUDIO_ADDR"; then'
}
