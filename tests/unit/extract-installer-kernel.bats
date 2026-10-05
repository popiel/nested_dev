#!/usr/bin/env bats
# tests/unit/extract-installer-kernel.bats — official bytes, addressed directly
#
# The extractor boots the stock installer with a host-owned command line
# (QEMU direct-kernel) instead of remastering media or typing at prompts.
# Its contract: parse the ISO's own grub config, prove both files against
# the ISO's shipped manifest, copy under versioned names, print the base
# args. The mount wrapper needs privilege and runs host-only (covered by
# the e2e mount stubs instead); everything here drives the functions
# against fixture trees through the source guard — no mounts, no network.

load '../lib/helpers'

SCRIPT="${PROJECT_ROOT}/provision/host/extract-installer-kernel.sh"

setup() {
    setup_mock_path
    WORK="$(mktemp -d)"
    export PVE_ROOT="$WORK"
    mkdir -p "${WORK}/var/log"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    ISO="${WORK}/fakeiso"
    mkdir -p "${ISO}/boot/grub" "${ISO}/casper"
    printf 'FAKEKERNELDATA' > "${ISO}/casper/vmlinuz"
    printf 'FAKEINITRDDATA' > "${ISO}/casper/initrd"
    cat > "${ISO}/boot/grub/grub.cfg" <<'EOF'
set default=0
menuentry "Install Ubuntu Server" {
    linux   /casper/vmlinuz  ro quiet splash ---
    initrd  /casper/initrd
}
EOF
    (cd "$ISO" && md5sum casper/vmlinuz casper/initrd > md5sum.txt)
    DEST="${WORK}/out"
}

teardown() {
    unset PVE_ROOT
    rm -rf "$WORK"
    cleanup_mocks
}

@test "happy path copies verified files and prints base args" {
    core_from_dir "$ISO" "$DEST" fake
    [ -f "${DEST}/fake-vmlinuz" ]
    [ -f "${DEST}/fake-initrd" ]
    run cat "${DEST}/fake-append"
    [ "$output" = "ro quiet splash ---" ]
    run cmp "${DEST}/fake-vmlinuz" "${ISO}/casper/vmlinuz"
    [ "$status" -eq 0 ]
}

@test "cache_current gates the skip path" {
    run cache_current "${ISO}/nonexistent.iso" "$DEST" fake
    [ "$status" -ne 0 ]
    touch "${WORK}/some.iso"
    core_from_dir "$ISO" "$DEST" fake
    run cache_current "${WORK}/some.iso" "$DEST" fake
    [ "$status" -eq 0 ]
}

@test "missing grub config dies naming it" {
    rm -rf "${ISO}/boot"
    run core_from_dir "$ISO" "$DEST" fake
    [ "$status" -ne 0 ]
    [[ "$output" == *"grub.cfg"* ]]
}

@test "tampered kernel fails the manifest check" {
    core_from_dir "$ISO" "$DEST" fake
    printf 'TAMPERED' > "${ISO}/casper/vmlinuz"
    run core_from_dir "$ISO" "$DEST" fake
    [ "$status" -ne 0 ]
    [[ "$output" == *"mismatch"* ]]
}

@test "manifest without the boot files dies loudly" {
    printf 'd41d8cd98f00b204e9800998ecf8427e  casper/other\n' > "${ISO}/md5sum.txt"
    run core_from_dir "$ISO" "$DEST" fake
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest covers no"* ]]
}

@test "initrd beside the kernel is found without a grub initrd line" {
    sed -i '/^[[:space:]]*initrd[[:space:]]/d' "${ISO}/boot/grub/grub.cfg"
    run core_from_dir "$ISO" "$DEST" fake
    [ "$status" -eq 0 ]
    [ -f "${DEST}/fake-initrd" ]
}
