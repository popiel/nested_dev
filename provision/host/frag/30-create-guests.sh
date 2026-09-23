#!/usr/bin/env bash
# frag/30-create-guests.sh — Create Desktop (100), LLM (101), Dev (102+) VMs
# Golden images imported via qm import-from; VMs created ready for first start.
# Idempotent. REF: host_os_v0.1
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

log "=== Guest VM creation ==="

# --- Detect host resources ---
TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
CPU_CORES=$(nproc)
FREE_DISK_GB=$(df -BG --output=avail /var/lib/vz | tail -1 | tr -d ' G')

log "Host: ${TOTAL_MEM_GB} GB RAM, ${CPU_CORES} cores, ${FREE_DISK_GB} GB free"

# --- Detect GPUs for passthrough ---
detect_gpu_pci() {
    local vendor_filter="$1"
    local ids=()
    while IFS= read -r line; do
        local addr=$(echo "$line" | awk '{print $1}')
        local vd=$(lspci -n -s "$addr" | awk '{print $3}')
        local v=$(echo "$vd" | cut -d: -f1)
        if [ "$v" = "$vendor_filter" ]; then
            ids+=("0000:${addr}")
            # Include audio companion if in separate IOMMU group
            local audio_addr=$(lspci -s "$addr" | grep -i audio | awk '{print $1}' || true)
            if [ -n "$audio_addr" ]; then
                local audio_group="/sys/bus/pci/devices/0000:${audio_addr}/iommu_group/devices"
                local gpu_group="/sys/bus/pci/devices/0000:${addr}/iommu_group/devices"
                # Only include audio if in a different group than its GPU
                if [ -d "$audio_group" ] && [ -d "$gpu_group" ]; then
                    if ! diff -q <(ls "$audio_group" | sort) <(ls "$gpu_group" | sort) >/dev/null 2>&1; then
                        ids+=("0000:${audio_addr}")
                    fi
                fi
            fi
        fi
    done < <(lspci | grep -iE 'vga|3d|display')
    IFS=,; echo "${ids[*]}"
}

# Detect iGPU (Intel or AMD)
IGPU_IDS=$(detect_gpu_pci "8086")
if [ -z "$IGPU_IDS" ]; then
    IGPU_IDS=$(detect_gpu_pci "1002")
fi

# Detect dGPUs (NVIDIA)
DGPU_IDS=$(detect_gpu_pci "10de")

log "iGPU passthrough: ${IGPU_IDS:-none}"
log "dGPU passthrough: ${DGPU_IDS:-none}"

# --- Memory allocation (32 GB profile) ---
DESKTOP_MEM=8192
DESKTOP_CORES=4
LLM_MEM=16384
LLM_CORES=6
DEV_MEM=8192
DEV_CORES=4

# Scale up if >32 GB available
if [ "$TOTAL_MEM_GB" -ge 64 ]; then
    DESKTOP_MEM=8192
    LLM_MEM=24576
    LLM_CORES=8
    log "64 GB+ host detected: LLM gets 24 GB"
fi

# --- VM 100: Desktop ---
if ! qm status 100 >/dev/null 2>&1; then
    DESKTOP_HOSTPCI=""
    if [ -n "$IGPU_IDS" ]; then
        DESKTOP_HOSTPCI="--hostpci0 ${IGPU_IDS},pcie=1,x-vga=0"
    fi

    # MAC: 52:54:00:00:01:00 — matches dnsmasq static lease in dnsmasq.conf
    qm create 100 \
        --name desktop \
        --memory "$DESKTOP_MEM" \
        --cores "$DESKTOP_CORES" \
        --cpu host \
        --scsihw virtio-scsi-single \
        --net0 virtio=52:54:00:00:01:00,bridge=vmbr0 \
        --ostype l26 \
        --bios ovmf \
        --machine q35 \
        --vga none \
        --serial0 socket \
        --agent enabled=1 \
        $DESKTOP_HOSTPCI \
        --ide0 local-lvm:0,import-from=/var/lib/vz/template/desktop-golden.qcow2 \
        --boot order=scsi0

    log "VM 100 (desktop) created: ${DESKTOP_MEM}MB, ${DESKTOP_CORES} cores, MAC 52:54:00:00:01:00"
else
    log "VM 100 already exists — skipping"
fi

# --- VM 101: LLM ---
if ! qm status 101 >/dev/null 2>&1; then
    LLM_HOSTPCI=""
    DGPU_INDEX=0
    if [ -n "$DGPU_IDS" ]; then
        IFS=',' read -ra DGPU_LIST <<< "$DGPU_IDS"
        for dgpu in "${DGPU_LIST[@]}"; do
            LLM_HOSTPCI="${LLM_HOSTPCI} --hostpci${DGPU_INDEX} ${dgpu},pcie=1"
            DGPU_INDEX=$((DGPU_INDEX + 1))
        done
    fi

    # Data volume: 500 GB default on 32 GB+ hosts
    DATA_VOL_SIZE=500

    # MAC: 52:54:00:00:01:01 — matches dnsmasq static lease in dnsmasq.conf
    qm create 101 \
        --name llm \
        --memory "$LLM_MEM" \
        --cores "$LLM_CORES" \
        --cpu host \
        --scsihw virtio-scsi-single \
        --net0 virtio=52:54:00:00:01:01,bridge=vmbr0 \
        --ostype l26 \
        --bios ovmf \
        --machine q35 \
        --vga none \
        --serial0 socket \
        --agent enabled=1 \
        $LLM_HOSTPCI \
        --ide0 local-lvm:0,import-from=/var/lib/vz/template/llm-golden.qcow2 \
        --scsi1 local-lvm:${DATA_VOL_SIZE},size=${DATA_VOL_SIZE}G \
        --boot order=scsi0

    # GeForce workaround: consumer NVIDIA needs hidden=1
    if [ -n "$DGPU_IDS" ]; then
        # Check if any dGPU is a consumer GeForce (not datacenter)
        # Datacenter GPUs typically have different device ID ranges
        # Apply workaround conservatively — it's harmless on datacenter GPUs
        qm set 101 --args '-cpu host,kvm=off,hidden=1'
        log "Applied GeForce kvm=off,hidden=1 workaround"
    fi

    log "VM 101 (llm) created: ${LLM_MEM}MB, ${LLM_CORES} cores, ${DATA_VOL_SIZE}GB data"
else
    log "VM 101 already exists — skipping"
fi

# --- VM 102: Dev template (clone source) ---
if ! qm status 102 >/dev/null 2>&1; then
    # MAC: 52:54:00:00:01:02 — matches dnsmasq static lease in dnsmasq.conf
    qm create 102 \
        --name dev-template \
        --memory "$DEV_MEM" \
        --cores "$DEV_CORES" \
        --cpu host \
        --scsihw virtio-scsi-single \
        --net0 virtio=52:54:00:00:01:02,bridge=vmbr0,firewall=1 \
        --ostype l26 \
        --bios ovmf \
        --machine q35 \
        --vga none \
        --serial0 socket \
        --agent enabled=1 \
        --ide0 local-lvm:0,import-from=/var/lib/vz/template/dev-golden.qcow2 \
        --boot order=scsi0

    log "VM 102 (dev-template) created: ${DEV_MEM}MB, ${DEV_CORES} cores"
else
    log "VM 102 already exists — skipping"
fi

log "=== Guest VM creation complete ==="
