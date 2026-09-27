#!/usr/bin/env bash
# frag/10-gpu-passthrough.sh — IOMMU + VFIO setup
# Auto-detects GPUs, validates IOMMU groups, configures passthrough.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

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

iommu_group_device_count() {
    # Number of devices in an IOMMU group directory. Echoes 0 when the directory
    # does not exist, so callers need no separate existence test.
    # Takes the directory as an argument rather than deriving it from sysfs, so
    # the separability rule is testable without a live /sys (tests/unit/frag10-iommu.bats).
    local group_path="$1"
    [ -d "$group_path" ] || { echo 0; return 0; }
    find "$group_path" -maxdepth 1 -type f | wc -l
}

iommu_group_is_separable() {
    # The R4 rule, on its own: a group holding more than one device cannot be
    # handed to VFIO without dragging the other devices along, so the GPU stops
    # working. This is the only statement of the rule; check_iommu_group_
    # separable and main() both go through it.
    [ "$(iommu_group_device_count "$1")" -le 1 ]
}

check_iommu_group_separable() {
    # BDF entry point: maps a PCI address to its IOMMU group directory, then
    # applies the rule. main() calls this rather than re-deriving the group
    # size, so the rule has exactly one implementation.
    local pci_addr="$1"
    iommu_group_is_separable \
        "/sys/bus/pci/devices/0000:${pci_addr}/iommu_group/devices"
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

    # --- Collect audio companion functions via IOMMU groups ---
    for name_entry in "${GPU_NAMES[@]}"; do
        PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
        GPU_GROUP_PATH="/sys/bus/pci/devices/0000:${PCI_ADDR}/iommu_group/devices"
        [ -d "$GPU_GROUP_PATH" ] || continue

        if ! check_iommu_group_separable "$PCI_ADDR"; then
            GROUP_DEVICES=$(find "$GPU_GROUP_PATH" -maxdepth 1 -type f -printf '%f ')
            log "ERROR: IOMMU group for $PCI_ADDR contains $(iommu_group_device_count "$GPU_GROUP_PATH") devices: $GROUP_DEVICES"
            log "  Group is NOT separable — aborting to prevent broken passthrough."
            log "  Fix: enable ACS override in BIOS/firmware, or use a different host."
            exit 1
        fi

            AUDIO_ADDR=$(find_audio_companion "$PCI_ADDR")
            if [ -n "$AUDIO_ADDR" ]; then
                AUDIO_VD=$(lspci -n -s "$AUDIO_ADDR" | awk '{print $3}')
                if ! check_iommu_group_separable "$AUDIO_ADDR"; then
                    log "ERROR: Audio companion $AUDIO_ADDR for GPU $PCI_ADDR is in a shared IOMMU group ($(iommu_group_device_count "/sys/bus/pci/devices/0000:${AUDIO_ADDR}/iommu_group/devices") devices)"
                    log "  Abort — audio function must be in the same group as its GPU or isolated."
                    exit 1
                fi
            AUDIO_IN_SET=false
            for id in "${GPU_IDS[@]}"; do
                if [ "$id" = "$AUDIO_VD" ]; then
                    AUDIO_IN_SET=true
                    break
                fi
            done
            if [ "$AUDIO_IN_SET" = false ]; then
                GPU_IDS+=("${AUDIO_VD}")
                log "Added audio companion $AUDIO_ADDR ($AUDIO_VD) for GPU $PCI_ADDR"
            fi
        else
            log "No audio companion found for GPU $PCI_ADDR"
        fi
    done

    # Build comma-separated vfio-pci.ids
    VFIO_IDS=$(IFS=,; echo "${GPU_IDS[*]}")
    log "vfio-pci.ids: $VFIO_IDS"

    # --- 1. GRUB cmdline ---
    GRUB_FILE="/etc/default/grub"
    if grep -q "intel_iommu=on\|amd_iommu=on" "$GRUB_FILE"; then
        log "GRUB IOMMU already configured"
    else
        sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${IOMMU_FLAG} iommu=pt\"|" "$GRUB_FILE"
        if ! grep -q "vfio-pci.ids" "$GRUB_FILE"; then
            sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 vfio-pci.ids=${VFIO_IDS} disable_vga=1\"|" "$GRUB_FILE"
        fi
        update-grub
        log "GRUB updated"
    fi

    # --- 2. modprobe early binding ---
    cat > /etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=${VFIO_IDS} disable_vga=1
softdep i915 pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep amdgpu pre: vfio-pci
EOF
    log "modprobe.d/vfio.conf written"

    # --- 3. modules-load ---
    cat > /etc/modules-load.d/vfio.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF
    log "modules-load.d/vfio.conf written"

    # --- 4. blacklist only passed-through GPU drivers ---
    BLACKLIST_FILE="/etc/modprobe.d/blacklist-gpu.conf"
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
    for name_entry in "${GPU_NAMES[@]}"; do
        PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
        VD=$(lspci -n -s "$PCI_ADDR" | awk '{print $3}')
        if echo "$VD" | grep -qi "^10de:"; then
            log "NVIDIA device detected at $PCI_ADDR — will apply kvm=off,hidden=1 at VM creation"
        fi
    done

    log "=== GPU passthrough setup complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
