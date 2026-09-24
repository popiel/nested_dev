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
    intel) IOMMU_FLAG="intel_iommu=on" ;;
    amd)   IOMMU_FLAG="amd_iommu=on" ;;
    *)     log "ERROR: Unknown CPU vendor: $CPU_VENDOR"; exit 1 ;;
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

    # Get audio companion if exists
    AUDIO_ADDR=$(lspci -s "$PCI_ADDR" | grep -i "audio" | awk '{print $1}' || true)

    GPU_IDS+=("${VENDOR}:${DEVICE}")
    GPU_NAMES+=("$PCI_ADDR $VENDOR_DEVICE $DESC")

    # Check IOMMU group
    IOMMU_GROUP_PATH="/sys/bus/pci/devices/0000:${PCI_ADDR}/iommu_group/devices"
    if [ -d "$IOMMU_GROUP_PATH" ]; then
        GROUP_SIZE=$(ls "$IOMMU_GROUP_PATH" | wc -l)
        if [ "$GROUP_SIZE" -gt 1 ]; then
            GROUP_DEVICES=$(ls "$IOMMU_GROUP_PATH" | tr '\n' ' ')
            log "WARNING: IOMMU group for $PCI_ADDR ($DESC) contains $GROUP_SIZE devices: $GROUP_DEVICES"
            log "  Group may not be separable. Verify before proceeding."
        else
            log "IOMMU group OK for $PCI_ADDR ($DESC): isolated"
        fi
    fi
done < <(lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}' | cut -d' ' -f1,3-)

if [ ${#GPU_IDS[@]} -eq 0 ]; then
    log "No GPUs detected — skipping VFIO setup"
    exit 0
fi

# --- Append audio companions to vfio-pci.ids ---
VFIO_IDS=$(IFS=,; echo "${GPU_IDS[*]}")

# For each GPU, also grab its audio function if in a separate IOMMU group
for name_entry in "${GPU_NAMES[@]}"; do
    PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
    AUDIO_ADDR=$(lspci -s "$PCI_ADDR" | grep -i "audio" | awk '{print $1}' || true)
    if [ -n "$AUDIO_ADDR" ]; then
        AUDIO_VD=$(lspci -n -s "$AUDIO_ADDR" | awk '{print $3}')
        if echo "$VFIO_IDS" | grep -q "$AUDIO_VD"; then
            continue  # already included
        fi
        VFIO_IDS="${VFIO_IDS},${AUDIO_VD}"
        log "Added audio companion $AUDIO_ADDR ($AUDIO_VD) for $PCI_ADDR"
    fi
done

log "vfio-pci.ids: $VFIO_IDS"

# --- 1. GRUB cmdline ---
GRUB_FILE="/etc/default/grub"
if grep -q "intel_iommu=on\|amd_iommu=on" "$GRUB_FILE"; then
    log "GRUB IOMMU already configured"
else
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${IOMMU_FLAG} iommu=pt\"|" "$GRUB_FILE"
    # Add vfio-pci.ids if not present
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
# Blacklist nvidia/nouveau only if a dGPU is being passed through
# Blacklist i915 only if the iGPU is being passed through
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
# Check if any passed-through NVIDIA device is a consumer GeForce
for name_entry in "${GPU_NAMES[@]}"; do
    PCI_ADDR=$(echo "$name_entry" | awk '{print $1}')
    VD=$(lspci -n -s "$PCI_ADDR" | awk '{print $3}')
    if echo "$VD" | grep -qi "^10de:"; then
        # Consumer GeForce devices typically have device IDs in certain ranges
        # The kvm=off,hidden=1 workaround is applied at VM creation time (frag/30)
        log "NVIDIA device detected at $PCI_ADDR — will apply kvm=off,hidden=1 at VM creation"
    fi
done

log "=== GPU passthrough setup complete ==="
