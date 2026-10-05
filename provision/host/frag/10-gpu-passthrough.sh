#!/usr/bin/env bash
# frag/10-gpu-passthrough.sh — IOMMU + VFIO setup
# Auto-detects GPUs, validates IOMMU groups, configures passthrough.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"
# Kernel interfaces, not provisioner outputs. Pointed at a fixture tree by the
# end-to-end test; the one production reader is the host's own kernel.
SYSFS="${PVE_SYSFS:-/sys}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }

# --- Functions for testability ---

detect_cpu_vendor() {
    lscpu | awk '/Vendor ID/{print tolower($3)}'
}

collect_gpu_ids() {
    # Populates GPU_IDS and GPU_NAMES arrays (passed by reference)
    # Excludes virtio VGA (vendor 1af4)
    local -n _ids=$1
    local -n _names=$2
    _ids=()
    _names=()

    while IFS= read -r line; do
        local pci_addr desc vendor_device vendor device
        pci_addr=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2-)

        vendor_device=$(lspci -n -s "$pci_addr" | awk '{print $3}')
        vendor=$(echo "$vendor_device" | cut -d: -f1)
        device=$(echo "$vendor_device" | cut -d: -f2)

        if [ "$vendor" = "1af4" ]; then
            log "Skipping virtio device at $pci_addr ($desc)"
            continue
        fi

        _ids+=("${vendor}:${device}")
        _names+=("$pci_addr $vendor_device $desc")
    done < <(lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}' | cut -d' ' -f1,3-)
}

find_audio_companion() {
    # Given a PCI address, find its audio companion via BDF prefix
    # Returns the BDF of the audio device, or empty string
    local gpu_addr="$1"
    local bus_prefix audio_addr
    bus_prefix="${gpu_addr%.*}"
    audio_addr=$(lspci -s "${bus_prefix}." | grep -i audio | awk '{print $1}' || true)
    echo "$audio_addr"
}

iommu_group_member_bdfs() {
    # The BDFs in a group, one per line, as the kernel actually publishes them.
    #
    # Counts directory *entries*, and does not match on file type. sysfs exposes
    # the members of a group as symlinks pointing at device directories:
    #   .../iommu_group/devices/0000:01:00.1 -> ../../../0000:01:00.1
    # so `find -type f` matches nothing and reports every real group as empty.
    # That silently disabled the separability rule, and the unit test did not
    # catch it because the mock was built from regular files — the one shape
    # -type f does match.
    local group_path="$1"
    [ -d "$group_path" ] || return 0
    find "$group_path" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true
}

iommu_group_device_count() {
    # Number of devices in an IOMMU group directory. Echoes 0 when the directory
    # does not exist, so callers need no separate existence test.
    # Takes the directory as an argument rather than deriving it from sysfs, so
    # the separability rule is testable without a live /sys (tests/unit/frag10-iommu.bats).
    local group_path="$1"
    [ -d "$group_path" ] || { echo 0; return 0; }
    find "$group_path" -mindepth 1 -maxdepth 1 -printf 'x\n' 2>/dev/null | wc -l
}

iommu_group_members() {
    # The BDFs in a group, space separated, for a diagnostic line.
    local group_path="$1"
    [ -d "$group_path" ] || return 0
    iommu_group_member_bdfs "$group_path" | tr '\n' ' '
    echo
}

iommu_group_number() {
    # The group number a device belongs to, or the empty string when the device
    # has none. The link is a symlink into /sys/kernel/iommu_groups/N, so two
    # devices share a group exactly when this returns the same value.
    local link="${SYSFS}/bus/pci/devices/0000:${1}/iommu_group"
    [ -L "$link" ] || { echo ""; return 0; }
    basename "$(readlink -f "$link")"
}

pci_bdf_short() {
    # A PCI address as bus:device.function, with any PCI domain dropped.
    #
    # sysfs names group members in full — 0000:01:00.0 — while lspci reports
    # them short — 01:00.0. Comparing the two needs the domain removed from one
    # side. It is removed rather than assumed to be "0000:" because a host whose
    # PCI domain is not zero would otherwise have every member look unrecognised
    # and the rule would reject a perfectly separable group. The domain is a
    # property of the machine, not of this rule.
    local b="${1##*/}"
    if [[ "$b" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
        printf '%s\n' "${b:5}"
    else
        printf '%s\n' "$b"
    fi
}

iommu_group_is_separable() {
    # The R4 rule, in one place. This is the only statement of it;
    # check_iommu_group_separable and main() both go through it.
    #
    #   $1  the group directory
    #   $2  the BDF being handed to VFIO
    #   $3+ BDFs permitted to share the group with it
    #
    # R-01.7.1 allows exactly two shapes: the device alone, or the device
    # together with its companion audio function. A count cannot express that —
    # the audio companion is itself a second device, so "more than one device"
    # and "unsafe" are different conditions. The previous version compared the
    # count against 1, which contradicts R-01.6.5; it only ever agreed with the
    # spec on real hardware because it counted zero devices for every group.
    local group_path="$1" bdf="$2"
    shift 2
    local member allowed allowed_bdf
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        # The device itself is always expected.
        [ "$(pci_bdf_short "$member")" = "$(pci_bdf_short "$bdf")" ] && continue
        allowed=false
        for allowed_bdf in "$@"; do
            [ "$(pci_bdf_short "$member")" = "$(pci_bdf_short "$allowed_bdf")" ] \
                && { allowed=true; break; }
        done
        [ "$allowed" = true ] || return 1
    done < <(iommu_group_member_bdfs "$group_path")
    return 0
}

check_iommu_group_separable() {
    # BDF entry point: maps a PCI address to its IOMMU group directory, then
    # applies the rule. main() calls this rather than re-deriving group
    # membership, so the rule has exactly one implementation.
    local pci_addr="$1"
    shift
    iommu_group_is_separable \
        "${SYSFS}/bus/pci/devices/0000:${pci_addr}/iommu_group/devices" \
        "$pci_addr" "$@"
}

iommu_group_blocked_by_host_bridge() {
    # True (0) when a group member that may not follow the device into the
    # guest is a PCI bridge (class 0604) — the ACS-splittable shape. Bridges
    # stay host-owned, so the group is viable for nobody until an override
    # splits it; endpoints bound elsewhere are a different refusal and do not
    # count here. Mirrors the separability iteration above on purpose: the two
    # predicates must agree on who is allowed in the group, and sharing the
    # loop would couple them.
    #   $1  the group directory
    #   $2  the BDF being handed to VFIO
    #   $3+ BDFs permitted to share the group with it
    local group_path="$1" bdf="$2"
    shift 2
    local member allowed allowed_bdf cls
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        [ "$(pci_bdf_short "$member")" = "$(pci_bdf_short "$bdf")" ] && continue
        allowed=false
        for allowed_bdf in "$@"; do
            [ "$(pci_bdf_short "$member")" = "$(pci_bdf_short "$allowed_bdf")" ] \
                && { allowed=true; break; }
        done
        [ "$allowed" = true ] && continue
        cls=$(lspci -n -s "$(pci_bdf_short "$member")" 2>/dev/null | awk '{print $2}' | cut -d: -f1 || true)
        [ "$cls" = "0604" ] && return 0
    done < <(iommu_group_member_bdfs "$group_path")
    return 1
}

iommu_flag_for_vendor() {
    # Maps a lowercased lscpu Vendor ID to the kernel parameter that enables
    # IOMMU on it. Returns 1 for a vendor with no known flag, so the caller
    # aborts rather than booting with IOMMU silently off.
    case "$1" in
        *intel*) echo "intel_iommu=on" ;;
        *amd*)   echo "amd_iommu=on" ;;
        *)       return 1 ;;
    esac
}

main() {
    log "=== GPU passthrough setup ==="

    # --- Detect CPU vendor for IOMMU flag ---
    CPU_VENDOR=$(detect_cpu_vendor)
    if ! IOMMU_FLAG=$(iommu_flag_for_vendor "$CPU_VENDOR"); then
        log "ERROR: Unknown CPU vendor: $CPU_VENDOR"
        exit 1
    fi
    log "CPU vendor: $CPU_VENDOR, IOMMU flag: $IOMMU_FLAG"

    # --- Collect all VGA/3D/compatible controllers ---
    GPU_IDS=()
    GPU_NAMES=()
    collect_gpu_ids GPU_IDS GPU_NAMES

    if [ ${#GPU_IDS[@]} -eq 0 ]; then
        log "No GPUs detected — skipping VFIO setup"
        exit 0
    fi

    # --- Judge each candidate on its own IOMMU group ---
    #
    # Separability is a property of a device, not of the host, so one unsafe
    # candidate does not make the others unsafe. The previous version exited on
    # the first non-separable group, which meant a single dGPU sharing a group
    # with a PCIe root port took down the run — including the iGPU that sat
    # alone in its own perfectly separable group, and every fragment after it.
    # On a host with an iGPU plus two dGPUs that produced no passthrough at all
    # and no guests, for a device that was never the problem.
    #
    # Unsafe candidates are dropped from the set and reported, which is what
    # "does not proceed quietly" asks for: the device is not passed through, and
    # the log says which group stopped it and what else was in it.
    PASSTHROUGH_IDS=()
    PASSTHROUGH_NAMES=()
    # Set when a skipped candidate shares its group with host bridges: the
    # override below splits exactly that shape. Never unset once set, and
    # never removed from GRUB afterwards — removing it would un-split the
    # groups on the next boot and flap working passthrough. Reversal is a
    # deliberate manual edit, matching R-01.7.7.
    ACS_NEEDED=false

    for name_entry in "${GPU_NAMES[@]}"; do
        PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
        GPU_GROUP_PATH="${SYSFS}/bus/pci/devices/0000:${PCI_ADDR}/iommu_group/devices"
        GPU_VD=$(lspci -n -s "$PCI_ADDR" | awk '{print $3}')
        GPU_DESC=$(echo "$name_entry" | cut -d' ' -f2-)

        # A device with no group directory is not in any IOMMU group, so nothing
        # can be assigned to it. The running kernel has no IOMMU for it.
        if [ ! -d "$GPU_GROUP_PATH" ]; then
            log "SKIP: $PCI_ADDR ($GPU_DESC) has no IOMMU group; it cannot be passed through."
            log "  Check: grep -o '[^ ]*iommu[^ ]*' /proc/cmdline ; dmesg | grep -i DMAR"
            continue
        fi

        # The companion audio function is part of the group shape R-01.7.1
        # permits, so it has to be identified before the group is judged.
        # Judging first and explaining afterwards made the normal pairing of a
        # GPU with its own audio function look like the unsafe case.
        AUDIO_ADDR=$(find_audio_companion "$PCI_ADDR")
        AUDIO_VD=""
        ALLOWED_IN_GROUP=()
        if [ -n "$AUDIO_ADDR" ]; then
            AUDIO_VD=$(lspci -n -s "$AUDIO_ADDR" | awk '{print $3}')
            if [ -n "$AUDIO_VD" ] && [ "$(iommu_group_number "$PCI_ADDR")" = "$(iommu_group_number "$AUDIO_ADDR")" ]; then
                ALLOWED_IN_GROUP=("$AUDIO_ADDR")
            fi
        fi

        if ! check_iommu_group_separable "$PCI_ADDR" ${ALLOWED_IN_GROUP[@]+"${ALLOWED_IN_GROUP[@]}"}; then
            log "SKIP: $PCI_ADDR ($GPU_DESC) is not in a separable IOMMU group."
            log "  Group $(iommu_group_number "$PCI_ADDR") holds: $(iommu_group_members "$GPU_GROUP_PATH")"
            log "  Permitted would be: $PCI_ADDR${ALLOWED_IN_GROUP[0]:+ and its companion audio function ${ALLOWED_IN_GROUP[0]}}"
            log "  The extra devices would follow it into the guest, so it is left to the host."
            log "  Fix: enable an ACS override in firmware to split the group, then re-run."
            if iommu_group_blocked_by_host_bridge "$GPU_GROUP_PATH" "$PCI_ADDR" ${ALLOWED_IN_GROUP[@]+"${ALLOWED_IN_GROUP[@]}"}; then
                ACS_NEEDED=true
                log "  Blocked by host bridge(s): adding pcie_acs_override to GRUB, which splits this shape at boot."
                log "  The devices attach only on a verified split after reboot — this run still skips them."
            fi
            continue
        fi

        # A companion in a group of its own has to be safe there on its own.
        if [ -n "$AUDIO_ADDR" ] && [ -z "${ALLOWED_IN_GROUP[0]:-}" ]; then
            AUDIO_GROUP_PATH="${SYSFS}/bus/pci/devices/0000:${AUDIO_ADDR}/iommu_group/devices"
            if [ -d "$AUDIO_GROUP_PATH" ] \
                && ! check_iommu_group_separable "$AUDIO_ADDR"; then
                log "SKIP: audio companion $AUDIO_ADDR for $PCI_ADDR is not separable on its own."
                log "  Group $(iommu_group_number "$AUDIO_ADDR") holds: $(iommu_group_members "$AUDIO_GROUP_PATH")"
                continue
            fi
        fi

        PASSTHROUGH_IDS+=("${GPU_VD}")
        PASSTHROUGH_NAMES+=("$PCI_ADDR $GPU_VD $GPU_DESC")

        if [ -n "$AUDIO_ADDR" ]; then
            PASSTHROUGH_IDS+=("${AUDIO_VD}")
            PASSTHROUGH_NAMES+=("$AUDIO_ADDR $AUDIO_VD audio companion for $PCI_ADDR")
            log "Added audio companion $AUDIO_ADDR ($AUDIO_VD) for GPU $PCI_ADDR"
        else
            log "No audio companion found for GPU $PCI_ADDR"
        fi
    done

    GPU_IDS=("${PASSTHROUGH_IDS[@]}")

    if [ ${#GPU_IDS[@]} -eq 0 ]; then
        log "ERROR: no display device is in a separable IOMMU group — nothing can be passed through."
        for name_entry in "${GPU_NAMES[@]}"; do
            PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
            log "  $PCI_ADDR: group $(iommu_group_number "$PCI_ADDR")$(iommu_group_number "$PCI_ADDR" || echo ' (none)')"
        done
        log "  Every candidate shares a group with a device it may not take. Aborting."
        exit 1
    fi

    log "Passthrough set (${#GPU_IDS[@]} device(s)):"
    for entry in "${PASSTHROUGH_NAMES[@]}"; do
        log "  $entry"
    done

    # --- Publish the accepted device set for frag/30 ---
    #
    # frag/30 attaches passthrough devices to guests, and it must attach exactly
    # this set — no more, no less. It used to run its own detection, which
    # listed every GPU on the host regardless of what this fragment decided: on
    # a host where the dGPUs were left to the host because their group was
    # unsafe, frag/30 still handed both 1080s to the LLM guest, which the kernel
    # had never bound to vfio-pci.
    #
    # One full BDF per line. frag/30 dies when this file is missing or empty
    # rather than guessing, so a skipped or failed frag/10 cannot silently
    # become guests without the devices they were built around.
    PASSTHROUGH_LIST="${ROOT}/var/lib/pve-firstboot/passthrough-devices"
    mkdir -p "$(dirname "$PASSTHROUGH_LIST")"
    : > "$PASSTHROUGH_LIST"
    for entry in "${PASSTHROUGH_NAMES[@]}"; do
        PCI_ADDR=$(echo "$entry" | awk '{print $1}')
        printf '0000:%s\n' "$PCI_ADDR" >> "$PASSTHROUGH_LIST"
    done
    log "Passthrough device list written to ${PASSTHROUGH_LIST}"

    # Build comma-separated vfio-pci.ids
    VFIO_IDS=$(IFS=,; echo "${GPU_IDS[*]}")
    log "vfio-pci.ids: $VFIO_IDS"

    # --- 1. GRUB cmdline ---
    #
    # Decided by comparing the tokens this run wants against the tokens already
    # present, not by asking whether IOMMU was ever switched on. The previous
    # test was `grep -q intel_iommu=on`, and it short-circuited the whole block:
    # on a host where the flag was already set but the passthrough set had since
    # changed — a device dropped as non-separable, a set narrowed to the iGPU —
    # vfio-pci.ids in GRUB was left holding the stale device list, so the
    # kernel bound devices the provisioner had decided to leave alone. That is
    # the one edit where being idempotent by flag-presence is worse than not
    # being idempotent at all.
    #
    # vfio-pci.ids is set-valued, so it is removed outright and re-appended
    # rather than compared or patched. Both alternatives misfire when the sets
    # overlap: narrowing `8086:5912,10de:...` to `8086:5912` makes "contains"
    # true and an in-place replace a prefix match, and either leaves the stale
    # token in the line next to the new one.
    GRUB_FILE="${ROOT}/etc/default/grub"
    # The match is anchored; the replacement is not. Sharing one variable for
    # both wrote a literal `^` at the start of the line on the first append —
    # update-grub then ignored the mangled variable, and a second run could not
    # match its own output to repair it.
    GRUB_LINE_MATCH='^GRUB_CMDLINE_LINUX_DEFAULT="'
    GRUB_LINE_PREFIX='GRUB_CMDLINE_LINUX_DEFAULT="'

    GRUB_CHANGED=false
    if grep -q -- " vfio-pci.ids=" "$GRUB_FILE" 2>/dev/null; then
        sed -i 's/ vfio-pci\.ids=[^ "]*//g' "$GRUB_FILE"
        GRUB_CHANGED=true
    fi

    grub_has_token() {
        grep -q -- " $1[\" ]" "$GRUB_FILE" 2>/dev/null
    }

    GRUB_TOKENS=("${IOMMU_FLAG}" "iommu=pt" "vfio-pci.ids=${VFIO_IDS}" "disable_vga=1")
    if [ "$ACS_NEEDED" = true ]; then
        GRUB_TOKENS+=("pcie_acs_override=downstream,multifunction")
    fi

    for token in "${GRUB_TOKENS[@]}"; do
        if ! grub_has_token "$token"; then
            sed -i "s|${GRUB_LINE_MATCH}\(.*\)\"|${GRUB_LINE_PREFIX}\1 ${token}\"|" "$GRUB_FILE"
            GRUB_CHANGED=true
        fi
    done

    if [ "$GRUB_CHANGED" = true ]; then
        update-grub
        log "GRUB updated"
        log "  A reboot is required before the passthrough set takes effect."
    else
        log "GRUB already matches the passthrough set"
    fi

    # --- 2. modprobe early binding ---
    mkdir -p "${ROOT}/etc/modprobe.d" "${ROOT}/etc/modules-load.d"
    cat > "${ROOT}/etc/modprobe.d/vfio.conf" <<EOF
options vfio-pci ids=${VFIO_IDS} disable_vga=1
softdep i915 pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep amdgpu pre: vfio-pci
EOF
    log "modprobe.d/vfio.conf written"

    # --- 3. modules-load ---
    cat > "${ROOT}/etc/modules-load.d/vfio.conf" <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF
    log "modules-load.d/vfio.conf written"

    # --- 4. blacklist only passed-through GPU drivers ---
    BLACKLIST_FILE="${ROOT}/etc/modprobe.d/blacklist-gpu.conf"
    : > "$BLACKLIST_FILE"

    if echo "$VFIO_IDS" | grep -qi "10de"; then
        {
            echo "blacklist nouveau"
            echo "blacklist nvidia"
            echo "blacklist nvidia_drm"
            echo "blacklist nvidia_modeset"
            echo "blacklist nvidia_uvm"
        } >> "$BLACKLIST_FILE"
        log "Blacklisted nvidia/nouveau (dGPU in passthrough set)"
    fi

    if echo "$VFIO_IDS" | grep -qi "8086"; then
        echo "blacklist i915" >> "$BLACKLIST_FILE"
        log "Blacklisted i915 (Intel iGPU in passthrough set)"
    fi

    if echo "$VFIO_IDS" | grep -qi "1002"; then
        echo "blacklist amdgpu" >> "$BLACKLIST_FILE"
        log "Blacklisted amdgpu (AMD GPU in passthrough set)"
    fi

    # --- 5. Update initramfs ---
    update-initramfs -u -k all
    log "initramfs updated"

    # --- 6. GeForce workaround (consumer NVIDIA) ---
    # Only for NVIDIA parts actually in the passthrough set. It walked every
    # detected GPU, so on a host where the dGPUs were left to the host because
    # their group was unsafe, it still logged that a workaround was coming — and
    # frag/30 applies it to a guest that will never receive that GPU.
    for entry in "${PASSTHROUGH_NAMES[@]}"; do
        PCI_ADDR=$(echo "$entry" | awk '{print $1}')
        VD=$(echo "$entry" | awk '{print $2}')
        if echo "$VD" | grep -qi "^10de:"; then
            log "NVIDIA device $PCI_ADDR is in the passthrough set — will apply kvm=off,hidden=1 at VM creation"
        fi
    done

    log "=== GPU passthrough setup complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
