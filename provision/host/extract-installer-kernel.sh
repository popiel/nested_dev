#!/usr/bin/env bash
# provision/host/extract-installer-kernel.sh — boot the stock installer with a
# host-owned command line, without remastering anything.
#
# Stock Ubuntu ISOs boot their installer without the `autoinstall` kernel
# flag, so Subiquity finds the NoCloud seed and waits on a yes/no prompt
# forever. PVE offers no knob to inject a guest ISO-boot command line, and
# remastering would trade the official-media pin for a media pipeline. QEMU
# direct-kernel boot is the third way: the ISO's own kernel and initrd,
# addressed directly, with the ISO still attached as the package source and
# the seed ISO untouched. Provenance stays official — both files are verified
# against the ISO's own shipped md5sum.txt before use.
#
# Usage: extract-installer-kernel.sh <iso-path> <dest-dir>
#   Prints the ISO's own kernel arguments (caller appends policy flags).
#   Outputs in <dest-dir>, skip-if-current: <base>-vmlinuz, <base>-initrd,
#   <base>-append.
#
# Testing split, deliberate: the mount wrapper needs privilege and runs only
# on the host (reviewed, plus covered end-to-end by the e2e mount stubs);
# every function below runs under bats against fixture trees via the
# source-guard, the same pattern frag/30 uses for its pure functions.
# Nothing is guessed across Ubuntu releases: no grub.cfg, no kernel line,
# no manifest coverage for both files — death naming which, not a best
# effort.
set -euo pipefail

ROOT="${PVE_ROOT:-}"
LOG="${ROOT}/var/log/pve-firstboot.log"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }
die() { log "FATAL: $*"; printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# Basename without .iso, e.g. ubuntu-26.04.1-live-server-amd64
iso_base() {
    local base
    base="$(basename "$1")"
    printf '%s\n' "${base%.iso}"
}

normpath() {
    # Grub says /casper/vmlinuz, manifests say ./casper/vmlinuz: compare
    # after the prefix so neither spelling silently misses.
    printf '%s\n' "$1" | sed -E 's|^[./]+||'
}

manifest_hash() {
    # Print the manifest's hash for the file, or nothing. md5sum format is
    # "<hash><spaces><path>"; the path is matched after normalization.
    local manifest="$1" want
    want="$(normpath "$2")"
    awk -v want="$want" '{f=$2; sub(/^\.\//, "", f); sub(/^\//, "", f); if (f == want) print $1}' \
        "$manifest" 2>/dev/null | head -1
}

# --- core: parse the bootloader config in an (already mounted) tree ---
grub_linux_line() {
    grep -E '^[[:space:]]*linux[[:space:]]' "$1/boot/grub/grub.cfg" 2>/dev/null | head -1
}

grub_initrd_rel() {
    grep -E '^[[:space:]]*initrd[[:space:]]' "$1/boot/grub/grub.cfg" 2>/dev/null \
        | head -1 | awk '{print $2}'
}

grub_base_args() {
    # The ISO's own kernel arguments, verbatim: the linux line minus the
    # command and the kernel path. The caller appends policy flags.
    printf '%s\n' "$1" | awk '$1 == "linux" {$1=$2=""; sub(/^ +/, ""); print}'
}

cache_current() {
    # True when all three outputs exist and are newer than the ISO.
    local iso="$1" dest="$2" base="$3"
    [ -f "$dest/$base-vmlinuz" ] && [ -f "$dest/$base-initrd" ] \
        && [ -f "$dest/$base-append" ] \
        && [ "$dest/$base-vmlinuz" -nt "$iso" ] \
        && [ "$dest/$base-append" -nt "$iso" ]
}

core_from_dir() {
    local dir="$1" dest="$2" base="$3"
    local grub="$dir/boot/grub/grub.cfg"
    [ -f "$grub" ] || die "no boot/grub/grub.cfg in $dir — unsupported ISO layout"
    local linux_line krel args irel
    linux_line="$(grub_linux_line "$dir")" || true
    [ -n "$linux_line" ] || die "no 'linux' line in $grub — unsupported ISO layout"
    krel="$(printf '%s\n' "$linux_line" | awk '{print $2}')"
    [ -n "$krel" ] || die "kernel path missing from grub linux line"
    args="$(grub_base_args "$linux_line")"
    irel="$(grub_initrd_rel "$dir")" || true
    if [ -z "$irel" ]; then
        # Fallback: initrd* beside the kernel. Grub names vary by release;
        # the manifest check below still binds whatever is found.
        local kdir cand f
        kdir="$(dirname "$krel")"
        cand=""
        for f in "$dir/$kdir"/initrd*; do
            [ -e "$f" ] || continue
            cand="$f"
            break
        done
        [ -n "$cand" ] || die "no initrd line in grub and no initrd* beside the kernel"
        irel="${cand#"$dir"/}"
    fi
    local ksrc="$dir/$krel" isrc="$dir/$irel"
    [ -f "$ksrc" ] || die "grub kernel $krel not present in $dir"
    [ -f "$isrc" ] || die "initrd $irel not present in $dir"
    local manifest="$dir/md5sum.txt"
    [ -f "$manifest" ] || die "no md5sum.txt in $dir — cannot prove official provenance"
    local want got
    want="$(manifest_hash "$manifest" "$krel")"
    [ -n "$want" ] || die "manifest covers no $krel — cannot prove official provenance"
    got="$(md5sum "$ksrc" | awk '{print $1}')"
    [ "$want" = "$got" ] || die "kernel md5 mismatch: manifest $want, file $got"
    want="$(manifest_hash "$manifest" "$irel")"
    [ -n "$want" ] || die "manifest covers no $irel — cannot prove official provenance"
    got="$(md5sum "$isrc" | awk '{print $1}')"
    [ "$want" = "$got" ] || die "initrd md5 mismatch: manifest $want, file $got"
    mkdir -p "$dest"
    cp "$ksrc" "$dest/$base-vmlinuz"
    cp "$isrc" "$dest/$base-initrd"
    printf '%s\n' "$args" > "$dest/$base-append"
    log "installer kernel extracted: $base (md5-verified against shipped manifest)"
}

main() {
    [ $# -eq 2 ] || { echo "usage: $0 <iso-path> <dest-dir>" >&2; exit 2; }
    local iso="$1" destdir="$2"
    [ -f "$iso" ] || die "no ISO at $iso"
    local base
    base="$(iso_base "$iso")"
    mkdir -p "${ROOT}/var/log"
    if cache_current "$iso" "${ROOT}/$destdir" "$base"; then
        log "installer kernel cache current: $base"
        cat "${ROOT}/$destdir/$base-append"
        exit 0
    fi
    # mnt is deliberately NOT local: the EXIT trap below fires after main()
    # returns, when locals are already unwound — under set -u that reads as
    # an unbound variable and turns every successful run into a failure.
    mnt="$(mktemp -d)"
    trap 'umount "$mnt" 2>/dev/null || true; rm -rf "$mnt" 2>/dev/null || true' EXIT
    mount -o loop,ro "$iso" "$mnt"
    core_from_dir "$mnt" "${ROOT}/$destdir" "$base"
    cat "${ROOT}/$destdir/$base-append"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
