#!/usr/bin/env bash
# frag/10-gpu-passthrough.sh — IOMMU + VFIO setup
# Auto-detects GPUs, validates IOMMU groups, configures passthrough.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

log "=== GPU passthrough setup ==="

# --- Detect CPU vendor for IOMMU flag ---
CPU_VENDOR=$(lscpu | awk '/Vendor ID/{print tolower($3)}')
case "$CPU_VENDOR" in
    *intel*) IOMMU_FLAG="intel_iommu=on" ;;
    *amd*)   IOMMU_FLAG="amd_iommu=on" ;;
    *)       log "ERROR: Unknown CPU vendor: $CPU_VENDOR"; exit 1 ;;
esac
log "CPU vendor: $CPU_VENDOR, IOMMU flag: $IOMMU_FLAG"

# --- Collect all VGA/3D/compatible controllers ---
# Format: vendor:device pairs for vfio-pci.ids
# Exclude virtio VGA (vendor 1af4) — that's the PVE display adapter
GPU_IDS=()
GPU_NAMES=()

while IFS= read -r line; do
    PCI_ADDR=$(echo "$line" | awk '{print $1}')
    DESC=$(echo "$line" | cut -d' ' -f2-)

    # Read vendor:device from the PCI device
    VENDOR_DEVICE=$(lspci -n -s "$PCI_ADDR" | awk '{print $3}')
    VENDOR=$(echo "$VENDOR_DEVICE" | cut -d: -f1)
    DEVICE=$(echo "$VENDOR_DEVICE" | cut -d: -f2)

    # Skip virtio display (host VGA)
    if [ "$VENDOR" = "1af4" ]; then
        log "Skipping virtio device at $PCI_ADDR ($DESC)"
        continue
    fi

    GPU_IDS+=("${VENDOR}:${DEVICE}")
    GPU_NAMES+=("$PCI_ADDR $VENDOR_DEVICE $DESC")
done < <(lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}' | cut -d' ' -f1,3-)

if [ ${#GPU_IDS[@]} -eq 0 ]; then
    log "No GPUs detected — skipping VFIO setup"
    exit 0
fi

# --- Collect audio companion functions via IOMMU groups ---
# For each GPU, check if its audio function sits in a separate IOMMU group
for name_entry in "${GPU_NAMES[@]}"; do
    PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
    GPU_GROUP_PATH="/sys/bus/pci/devices/0000:${PCI_ADDR}/iommu_group/devices"
    [ -d "$GPU_GROUP_PATH" ] || continue

    GPU_GROUP_SIZE=$(ls "$GPU_GROUP_PATH" | wc -l)

    # Check IOMMU group separability (Spec 01 §5.1 R4)
    if [ "$GPU_GROUP_SIZE" -gt 1 ]; then
        GROUP_DEVICES=$(ls "$GPU_GROUP_PATH" | tr '\n' ' ')
        log "ERROR: IOMMU group for $PCI_ADDR contains $GROUP_SIZE devices: $GROUP_DEVICES"
        log "  Group is NOT separable — aborting to prevent broken passthrough."
        log "  Fix: enable ACS override in BIOS/firmware, or use a different host."
        exit 1
    fi

    # Find the audio function — same bus, next function number
    AUDIO_ADDR=$(lspci -s "$PCI_ADDR" | sed -n 's/.*\[\(Audio\).*/\1/p; t found; d; :found' || true)
    # Fallback: look for any audio device on the same BDF domain:bus
    if [ -z "$AUDIO_ADDR" ]; then
        # Extract bus:device prefix (e.g. "01:00" from "01:00.0")
        BUS_PREFIX=$(echo "$PCI_ADDR" | sed 's/\.[0-9]$//')
        AUDIO_ADDR=$(lspci -s "${BUS_PREFIX}." | grep -i audio | awk '{print $1}' || true)
    fi
    if [ -n "$AUDIO_ADDR" ]; then
        AUDIO_VD=$(lspci -n -s "$AUDIO_ADDR" | awk '{print $3}')
        AUDIO_GROUP_PATH="/sys/bus/pci/devices/0000:${AUDIO_ADDR}/iommu_group/devices"
        if [ -d "$AUDIO_GROUP_PATH" ]; then
            AUDIO_GROUP_SIZE=$(ls "$AUDIO_GROUP_PATH" | wc -l)
            if [ "$AUDIO_GROUP_SIZE" -gt 1 ]; then
                log "ERROR: Audio companion $AUDIO_ADDR for GPU $PCI_ADDR is in a shared IOMMU group (${AUDIO_GROUP_SIZE} devices)"
                log "  Abort — audio function must be in the same group as its GPU or isolated."
                exit 1
            fi
        fi
        # Add audio companion to passthrough set
        # Check if already in the set
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
    echo "blacklist nouveau" >> "$BLACKLIST_FILE"
    echo "blacklist nvidia" >> "$BLACKLIST_FILE"
    echo "blacklist nvidia_drm" >> "$BLACKLIST_FILE"
    echo "blacklist nvidia_modeset" >> "$BLACKLIST_FILE"
    echo "blacklist nvidia_uvm" >> "$BLACKLIST_FILE"
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
