#!/usr/bin/env bats
# tests/unit/boot-order.bats — boot-usb-first.sh against a stub firmware.
#
# Reordering the wrong boot entry boots the wrong OS, so the matching and
# ordering logic is exercised here instead of trusted: a stateful efibootmgr
# stub serves a canned entry list, records the -o invocation, and reports the
# new order back, which is what the script's own verification reads.

load '../lib/helpers'

SCRIPT="${PROJECT_ROOT}/provision/host/boot-usb-first.sh"

setup() {
    setup_mock_path
    WORK="${BATS_TMPDIR}/bootorder"
    rm -rf "$WORK"
    mkdir -p "$WORK/efi" "$WORK/state"
    # efibootmgr answers -v from a canned list, records -o, and reports the
    # order it was given — the script's verify step reads that back.
    cat > "${FIXTURES_DIR}/mock-bin/efibootmgr" <<'EOF'
#!/bin/bash
STATE="${EFIBOOTMGR_STATE:?EFIBOOTMGR_STATE not set}"
case "${1:-}" in
  -v) cat "$STATE/entries" ;;
  -o) printf 'efibootmgr %s\n' "$*" >> "$STATE/journal"
      printf '%s\n' "$2" > "$STATE/order" ;;
  *) printf 'BootCurrent: 0000\nBootOrder: %s\n' "$(cat "$STATE/order")" ;;
esac
EOF
    chmod +x "${FIXTURES_DIR}/mock-bin/efibootmgr"
    # id -u must be 0; the tests do not run as root.
    printf '#!/bin/bash\necho 0\n' > "${FIXTURES_DIR}/mock-bin/id"
    chmod +x "${FIXTURES_DIR}/mock-bin/id"
    export EFIBOOTMGR_STATE="$WORK/state"
    export EFIVARS="$WORK/efi"
}

teardown() {
    unset EFIBOOTMGR_STATE EFIVARS
    rm -rf "$WORK"
    cleanup_mocks
}

write_entries() {
    cat > "$WORK/state/entries"
    printf '%s\n' "$1" > "$WORK/state/order"
}

run_tool() {
    run env EFIBOOTMGR_STATE="$WORK/state" EFIVARS="$WORK/efi" bash "$SCRIPT" "$@"
}

@test "the USB entry moves first, everything else keeps its order" {
    write_entries "0000,0002,0001" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
Boot0001* UEFI: SanDisk, Partition 1	PciRoot(0x0)/USB(0x0,0x0)/HD(1,MBR,...)
Boot0002* UEFI: PXE IPv4 Intel(R) Ethernet	PciRoot(0x0)/MAC(...)
EOF
    run_tool usb
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified: 0001"* ]]
    run grep -q "efibootmgr -o 0001,0000,0002" "$WORK/state/journal"
    [ "$status" -eq 0 ]
}

@test "an already-first USB entry changes nothing" {
    write_entries "0001,0000" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
Boot0001* UEFI: SanDisk, Partition 1	PciRoot(0x0)/USB(0x0,0x0)/HD(1,MBR,...)
EOF
    run_tool
    [ "$status" -eq 0 ]
    [[ "$output" == *"already first"* ]]
    [ ! -e "$WORK/state/journal" ] || {
        echo "boot order rewritten despite already being correct" >&2
        return 1
    }
}

@test "no match aborts without touching the boot order" {
    write_entries "0000" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
EOF
    run_tool usb
    [ "$status" -ne 0 ]
    [[ "$output" == *"no boot entry matches"* ]]
    [ ! -e "$WORK/state/journal" ]
}

@test "an ambiguous pattern aborts without touching the boot order" {
    write_entries "0000,0001,0002" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
Boot0001* UEFI: SanDisk, Partition 1	PciRoot(0x0)/USB(0x0,0x0)/HD(1,MBR,...)
Boot0002* UEFI: USB HDD Secondary	PciRoot(0x0)/USB(0x1,0x0)/HD(1,MBR,...)
EOF
    run_tool usb
    [ "$status" -ne 0 ]
    [[ "$output" == *"narrow it down"* ]]
    [ ! -e "$WORK/state/journal" ]
}

@test "a custom pattern selects a non-USB entry" {
    write_entries "0000,0002" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
Boot0002* UEFI: PXE IPv4 Intel(R) Ethernet	PciRoot(0x0)/MAC(...)
EOF
    run_tool pxe
    [ "$status" -eq 0 ]
    run grep -q "efibootmgr -o 0002,0000" "$WORK/state/journal"
    [ "$status" -eq 0 ]
}

@test "legacy boot without EFI variables fails clearly" {
    rm -rf "$WORK/efi"
    write_entries "0000" <<'EOF'
Boot0000* proxmox	HD(1,GPT,...)/File(\EFI\proxmox\grubx64.efi)
EOF
    run_tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"legacy boot"* ]]
}
