#!/usr/bin/env bash
# provision/host/boot-usb-first.sh — put the USB installer first in UEFI boot order
#
# Reinstalls happen from a USB stick, and fighting the firmware boot menu each
# time means walking to the box. This moves the USB entry to the front of
# BootOrder in NVRAM (which survives wipes — that is the point) while leaving
# every other entry and its relative order untouched, so normal boots fall
# through to the PVE entry whenever no stick is present.
#
# Usage: boot-usb-first.sh [pattern]      (default pattern: usb)
#
# The pattern matches boot entry labels case-insensitively. Exactly one entry
# must match — zero or several is an error that lists what was found, because
# guessing between boot entries is how a host ends up unbootable. Nothing is
# ever deleted; only the order changes.
set -euo pipefail

PATTERN="${1:-usb}"
# Overridable for tests; the real firmware variables live here.
EFIVARS="${EFIVARS:-/sys/firmware/efi}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (writing EFI variables)"
[ -d "$EFIVARS" ] || die "no EFI variables at ${EFIVARS} — legacy boot has no UEFI boot order to change"

if ! command -v efibootmgr >/dev/null 2>&1; then
    echo "installing efibootmgr..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y efibootmgr
fi

# Collect "number label" pairs, e.g. Boot0001* UEFI: SanDisk -> "0001 UEFI: SanDisk".
entries="$(efibootmgr -v | grep -E '^Boot[0-9A-Fa-f]{4}')"
[ -n "$entries" ] || die "no boot entries reported by efibootmgr"

matches=""
while IFS= read -r line; do
    [ -n "$line" ] || continue
    num="$(printf '%s\n' "$line" | grep -oE '^Boot[0-9A-Fa-f]{4}' | cut -c5-)"
    label="$(printf '%s\n' "$line" | sed 's/^Boot[0-9A-Fa-f]\{4\}\*\{0,1\} //')"
    shopt -s nocasematch
    if [[ "$label" == *"$PATTERN"* ]]; then
        matches="${matches}${matches:+$'\n'}${num} ${label}"
    fi
    shopt -u nocasematch
done <<< "$entries"

count="$(printf '%s\n' "$matches" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
    echo "no boot entry matches '${PATTERN}'. Entries:" >&2
    printf '%s\n' "$entries" >&2
    exit 1
fi
if [ "$count" -gt 1 ]; then
    echo "pattern '${PATTERN}' matches ${count} entries; narrow it down:" >&2
    printf '%s\n' "$matches" >&2
    exit 1
fi
match_num="$(printf '%s\n' "$matches" | awk '{print $1}')"
match_label="$(printf '%s\n' "$matches" | cut -d' ' -f2-)"

# Current order, falling back to numeric entry order when none is set.
current="$(efibootmgr | grep -E '^BootOrder:' | cut -d: -f2 | tr -d ' ' || true)"
if [ -z "$current" ]; then
    current="$(printf '%s\n' "$entries" | grep -oE '^Boot[0-9A-Fa-f]{4}' | cut -c5- | tr '\n' ',' | sed 's/,$//')"
fi

first="${current%%,*}"
if [ "$first" = "$match_num" ]; then
    echo "already first: ${match_num} ${match_label}"
    exit 0
fi

# Matched entry front, everything else in its current relative order.
rest="$(printf '%s\n' "$current" | tr ',' '\n' | grep -vxF "$match_num" | tr '\n' ',' | sed 's/,$//')"
if [ -n "$rest" ]; then
    new_order="${match_num},${rest}"
else
    new_order="$match_num"
fi

echo "current order: $current"
echo "new order:     $new_order  (${match_label} first)"
efibootmgr -o "$new_order" >/dev/null

# Verify the firmware took it — a silent no-op here reboots into the wrong OS.
verify="$(efibootmgr | grep -E '^BootOrder:' | cut -d: -f2 | tr -d ' ' || true)"
if [ "${verify%%,*}" != "$match_num" ]; then
    die "BootOrder does not start with ${match_num} after setting it (got: '${verify}')"
fi
echo "verified: ${match_num} ${match_label} boots first"
