#!/usr/bin/env bats
# tests/unit/gpu-detect.bats — test detect_gpu_pci from frag/30

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
}

teardown() {
    cleanup_mocks
}

# Installs the shared lspci mock, serving one fixture and one device table.
# The tests below differ only in those two inputs and the vendor they ask for,
# so the mock body is written once in tests/fixtures/mock-lspci.sh.
#
# $1 = fixture name under tests/fixtures
# $2... = <bdf>=<vendor:device> pairs
lspci_mock() {
    local fixture="$1"; shift
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/${fixture}"
    export LSPCI_TABLE="$*"
}

@test "detect_gpu_pci returns the matching GPU from a multi-GPU host" {
    lspci_mock "lspci-multi-gpu.txt" "01:00.0=10de:2204" "01:00.1=10de:1aef"
    run detect_gpu_pci "10de"
    assert_contains "$output" "0000:01:00.0"
}

@test "detect_gpu_pci returns empty for a vendor that is not present" {
    lspci_mock "lspci-single-gpu.txt" "01:00.0=10de:2204" "00:02.0=8086:9bc5"
    run detect_gpu_pci "1234"
    [ -z "$output" ]
}

@test "detect_gpu_pci excludes the non-matching vendor on the same host" {
    # A host with both an NVIDIA and an Intel GPU: asking for 10de must not
    # pick up the iGPU, or the guest gets a passthrough id for a device the
    # host is still using.
    lspci_mock "lspci-single-gpu.txt" "01:00.0=10de:2204" "00:02.0=8086:9bc5"
    run detect_gpu_pci "10de"
    assert_contains "$output" "0000:01:00.0"
    assert_not_contains "$output" "0000:00:02.0"
}

@test "detect_gpu_pci returns the virtio device when explicitly asked for" {
    # detect_gpu_pci filters on whatever vendor it is handed; excluding virtio
    # is collect_gpu_ids' job (see tests/unit/frag10-iommu.bats). This pins the
    # boundary between the two so neither grows the other's rule.
    lspci_mock "lspci-no-gpu.txt" "04:00.0=1af4:1050"
    run detect_gpu_pci "1af4"
    assert_contains "$output" "0000:04:00.0"
}
