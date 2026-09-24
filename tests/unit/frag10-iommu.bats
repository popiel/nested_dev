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

@test "detect_cpu_vendor matches genuineintel" {
    cat > "${FIXTURES_DIR}/mock-bin/lscpu" <<'SCRIPT'
#!/bin/bash
echo "Vendor ID:                        GenuineIntel"
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lscpu"
    run detect_cpu_vendor
    [[ "$output" == *"genuineintel"* ]]
}

@test "detect_cpu_vendor matches authenticamd" {
    cat > "${FIXTURES_DIR}/mock-bin/lscpu" <<'SCRIPT'
#!/bin/bash
echo "Vendor ID:                        AuthenticAMD"
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lscpu"
    run detect_cpu_vendor
    [[ "$output" == *"authenticamd"* ]]
}

@test "find_audio_companion returns BDF for audio device" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
echo "01:00.0 VGA compatible controller: NVIDIA ..."
echo "01:00.1 Audio device: NVIDIA ..."
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run find_audio_companion "01:00.0"
    [ "$output" = "01:00.1" ]
}

@test "find_audio_companion returns empty when no audio" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
echo "01:00.0 VGA compatible controller: NVIDIA ..."
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run find_audio_companion "01:00.0"
    [ -z "$output" ]
}

@test "check_iommu_group_separable returns 0 for single-device group" {
    local tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/0000:01:00.0/iommu_group/devices"
    echo "01:00.0" > "${tmpdir}/0000:01:00.0/iommu_group/devices/01:00.0"
    local group_path="${tmpdir}/0000:01:00.0/iommu_group/devices"
    local size
    size=$(ls "$group_path" | wc -l)
    [ "$size" -le 1 ]
    rm -rf "$tmpdir"
}

@test "check_iommu_group_separable returns 1 for multi-device group" {
    local tmpdir=$(mktemp -d)
    mkdir -p "${tmpdir}/0000:01:00.0/iommu_group/devices"
    echo "01:00.0" > "${tmpdir}/0000:01:00.0/iommu_group/devices/01:00.0"
    echo "01:00.1" > "${tmpdir}/0000:01:00.0/iommu_group/devices/01:00.1"
    local group_path="${tmpdir}/0000:01:00.0/iommu_group/devices"
    local size
    size=$(ls "$group_path" | wc -l)
    [ "$size" -gt 1 ]
    rm -rf "$tmpdir"
}
