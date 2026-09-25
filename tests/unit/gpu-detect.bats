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

@test "detect_gpu_pci includes NVIDIA GPU" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
if [[ "$*" == *"-n -s"* ]]; then
    BDF=$(echo "$*" | awk '{print $NF}')
    case "$BDF" in
        01:00.0) echo "01:00.0 0300: 10de:2204" ;;
        01:00.1) echo "01:00.1 0403: 10de:1aef" ;;
        00:02.0) echo "00:02.0 0300: 8086:9bc5" ;;
        04:00.0) echo "04:00.0 0300: 1af4:1050" ;;
    esac
elif [[ "$*" == *"-s"* && "$*" != *"-n"* ]]; then
    echo "01:00.0 VGA compatible controller: NVIDIA ..."
    echo "01:00.1 Audio device: NVIDIA ..."
else
    cat "${FIXTURES_DIR}/lspci-multi-gpu.txt"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run detect_gpu_pci "10de"
    assert_contains "$output" "0000:01:00.0"
}

@test "detect_gpu_pci returns empty for non-existent vendor" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
if [[ "$*" == *"-n -s"* ]]; then
    BDF=$(echo "$*" | awk '{print $NF}')
    case "$BDF" in
        01:00.0) echo "01:00.0 0300: 10de:2204" ;;
    esac
else
    cat "${FIXTURES_DIR}/lspci-single-gpu.txt"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run detect_gpu_pci "1234"
    [ -z "$output" ]
}

@test "detect_gpu_pci returns single GPU for single-gpu fixture" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
if [[ "$*" == *"-n -s"* ]]; then
    BDF=$(echo "$*" | awk '{print $NF}')
    case "$BDF" in
        01:00.0) echo "01:00.0 0300: 10de:2204" ;;
        00:02.0) echo "00:02.0 0300: 8086:9bc5" ;;
    esac
else
    cat "${FIXTURES_DIR}/lspci-single-gpu.txt"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run detect_gpu_pci "10de"
    assert_contains "$output" "0000:01:00.0"
    assert_not_contains "$output" "0000:04:00.0"
}

@test "detect_gpu_pci excludes non-matching vendors" {
    cat > "${FIXTURES_DIR}/mock-bin/lspci" <<'SCRIPT'
#!/bin/bash
if [[ "$*" == *"-n -s"* ]]; then
    BDF=$(echo "$*" | awk '{print $NF}')
    case "$BDF" in
        01:00.0) echo "01:00.0 0300: 10de:2204" ;;
        00:02.0) echo "00:02.0 0300: 8086:9bc5" ;;
    esac
else
    cat "${FIXTURES_DIR}/lspci-single-gpu.txt"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/lspci"
    run detect_gpu_pci "10de"
    assert_contains "$output" "0000:01:00.0"
    assert_not_contains "$output" "0000:00:02.0"
}
