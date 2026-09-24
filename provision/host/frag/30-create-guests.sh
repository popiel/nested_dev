#!/usr/bin/env bash
# frag/30-create-guests.sh — Create Desktop (100), LLM (101), Dev Template (102)
# NoCloud seeds: fetches user-data templates from GitHub, injects password hash
# (+ vmctl private key for desktop), builds seed ISOs, creates VMs with official
# Ubuntu ISO + NoCloud seed. Desktop and LLM are started immediately.
# Dev template (102) is provisioned once then converted to PVE template.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }
die() { log "FATAL: $*"; exit 1; }

# --- Pure functions (testable via source-guard) ---

resolve_ref_to_sha() {
    local repo="$1" ref="$2"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$ref"
        return
    fi
    local sha=""
    sha=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}')
    if [ -z "$sha" ]; then
        sha=$(git ls-remote "https://github.com/${repo}.git" "refs/tags/${ref}" 2>/dev/null | awk '{print $1}')
    fi
    echo "$sha"
}

detect_gpu_pci() {
    local vendor_filter="$1"
    local ids=()
    while IFS= read -r line; do
        local addr
        addr=$(echo "$line" | awk '{print $1}')
        local vd
        vd=$(lspci -n -s "$addr" | awk '{print $3}')
        local v
        v=$(echo "$vd" | cut -d: -f1)
        if [ "$v" = "$vendor_filter" ]; then
            ids+=("0000:${addr}")
            # Find audio companion via BDF prefix (same bus, next function)
            local bus_prefix
            bus_prefix="${addr%.*}"
            local audio_addr
            audio_addr=$(lspci -s "${bus_prefix}." | grep -i audio | awk '{print $1}' || true)
            if [ -n "$audio_addr" ]; then
                local audio_group="/sys/bus/pci/devices/0000:${audio_addr}/iommu_group/devices"
                local gpu_group="/sys/bus/pci/devices/0000:${addr}/iommu_group/devices"
                if [ -d "$audio_group" ] && [ -d "$gpu_group" ]; then
                    if ! diff -q <(ls "$audio_group" | sort) <(ls "$gpu_group" | sort) >/dev/null 2>&1; then
                        # Separate IOMMU group — include audio in passthrough
                        local audio_in_set=false
                        for existing_id in "${ids[@]}"; do
                            local existing_vd
                            existing_vd="${existing_id#0000:}"
                            local audio_vd
                            audio_vd=$(lspci -n -s "$audio_addr" | awk '{print $3}')
                            if [ "$existing_vd" = "$audio_vd" ]; then
                                audio_in_set=true
                                break
                            fi
                        done
                        if [ "$audio_in_set" = false ]; then
                            ids+=("0000:${audio_addr}")
                            log "Added audio companion $audio_addr for GPU $addr"
                        fi
                    fi
                fi
            fi
        fi
    done < <(lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}' | cut -d' ' -f1,3-)
    IFS=,; echo "${ids[*]}"
}

download_iso() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        log "ISO already present: $(basename "$dest")"
        return
    fi
    log "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url" 2>&1 | tee -a /var/log/pve-firstboot.log
    log "Downloaded: $(sha256sum "$dest" | awk '{print $1}')"
}

# --- Main execution (guarded for source-testability) ---

main() {
    # --- Source shared personalization (§05) ---
    . /root/provision/personalization.sh 2>/dev/null || true
    GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
    GITHUB_REF="${PERSONALIZATION_REF:-main}"

    REF_SHA=$(resolve_ref_to_sha "${GITHUB_REPO}" "${GITHUB_REF}")
    if [ -n "$REF_SHA" ]; then
        log "GitHub REF resolved: ${GITHUB_REF} -> ${REF_SHA:0:12}"
    else
        log "WARNING: Could not resolve REF '${GITHUB_REF}' — proceeding with branch name only"
    fi

    GITHUB_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"

    log "=== Guest VM creation ==="

    # --- Source Ubuntu release config ---
    . /root/provision/ubuntu-release.conf 2>/dev/null || {
        UBUNTU_VERSION="26.04"
        UBUNTU_CODENAME="noble"
    }
    UBUNTU_BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
    UBUNTU_DESKTOP_ISO="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
    UBUNTU_SERVER_ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

    # --- Detect host resources ---
    TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    CPU_CORES=$(nproc)
    FREE_DISK_GB=$(df -BG --output=avail /var/lib/vz | tail -1 | tr -d ' G')

    log "Host: ${TOTAL_MEM_GB} GB RAM, ${CPU_CORES} cores, ${FREE_DISK_GB} GB free"

    # --- Detect GPUs for passthrough ---
    IGPU_IDS=$(detect_gpu_pci "8086")
    if [ -z "$IGPU_IDS" ]; then
        IGPU_IDS=$(detect_gpu_pci "1002")
    fi
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

    if [ "$TOTAL_MEM_GB" -ge 64 ]; then
        DESKTOP_MEM=8192
        LLM_MEM=24576
        LLM_CORES=8
        log "64 GB+ host detected: LLM gets 24 GB"
    fi

    # --- Read password hash ---
    PASSWORD_HASH_FILE="/root/.password-hash"
    [ -f "$PASSWORD_HASH_FILE" ] || die "Password hash not found: ${PASSWORD_HASH_FILE}"
    PASS_HASH="$(cat "$PASSWORD_HASH_FILE")"
    log "Password hash loaded"

    # --- Read vmctl private key (base64 for desktop injection) ---
    VMCTL_KEY_FILE="/root/.nested-dev/vmctl-priv-staged"
    VMCTL_KEY_B64=""
    if [ -f "$VMCTL_KEY_FILE" ]; then
        VMCTL_KEY_B64=$(base64 -w0 "$VMCTL_KEY_FILE" 2>/dev/null || base64 "$VMCTL_KEY_FILE" 2>/dev/null)
        log "vmctl private key loaded for desktop seed injection"
    else
        log "WARNING: vmctl private key not found at ${VMCTL_KEY_FILE} — desktop control may not work"
    fi

    # --- Create NoCloud seed directory ---
    SEED_DIR="/var/lib/vz/template/cidata"
    mkdir -p "$SEED_DIR"

    # --- Install genisoimage if needed ---
    if ! command -v genisoimage >/dev/null 2>&1; then
        log "Installing genisoimage..."
        apt-get update -qq 2>/dev/null
        apt-get install -y genisoimage 2>&1 | tail -1 >> /var/log/pve-firstboot.log
        log "genisoimage installed"
    fi

    # --- Fetch user-data templates and inject placeholders ---
    for guest in desktop llm dev; do
        TEMPLATE_URL="${GITHUB_BASE_URL}/${guest}/user-data/user-data"
        SEED_FILE="${SEED_DIR}/${guest}-user-data"

        if ! wget -q "$TEMPLATE_URL" -O "${SEED_DIR}/${guest}-template" 2>/dev/null; then
            log "WARNING: Could not fetch ${guest} user-data from GitHub"
            continue
        fi

        if [ -z "${PERSONALIZATION_USERNAME:-}" ] || [ -z "${PERSONALIZATION_FULLNAME:-}" ]; then
            log "ERROR: PERSONALIZATION_USERNAME or PERSONALIZATION_FULLNAME not set — check /root/provision/personalization.sh"
            exit 1
        fi
        sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
            -e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g" \
            -e "s|__PERSONALIZATION_USERNAME__|${PERSONALIZATION_USERNAME}|g" \
            -e "s|__PERSONALIZATION_FULLNAME__|${PERSONALIZATION_FULLNAME}|g" \
            -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
            "${SEED_DIR}/${guest}-template" > "$SEED_FILE"

        echo "instance-id: ${guest}-$(date +%s)" > "${SEED_DIR}/${guest}-meta-data"

        genisoimage -r -V cidata -joliet-long -o "${SEED_DIR}/${guest}-seed.iso" \
            "$SEED_FILE" "${SEED_DIR}/${guest}-meta-data" 2>/dev/null

        log "NoCloud seed prepared: ${guest}"
    done

    # --- Download Ubuntu ISOs if not present ---
    ISO_DIR="/var/lib/vz/template/iso"
    mkdir -p "$ISO_DIR"
    download_iso "${UBUNTU_BASE_URL}/${UBUNTU_DESKTOP_ISO}" "${ISO_DIR}/${UBUNTU_DESKTOP_ISO}"
    download_iso "${UBUNTU_BASE_URL}/${UBUNTU_SERVER_ISO}" "${ISO_DIR}/${UBUNTU_SERVER_ISO}"

    # --- VM 100: Desktop ---
    if ! qm status 100 >/dev/null 2>&1; then
        DESKTOP_HOSTPCI=""
        if [ -n "$IGPU_IDS" ]; then
            DESKTOP_HOSTPCI="--hostpci0 ${IGPU_IDS},pcie=1,x-vga=0"
        fi

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
            ${DESKTOP_HOSTPCI:+"$DESKTOP_HOSTPCI"} \
            --cdrom0 "${ISO_DIR}/${UBUNTU_DESKTOP_ISO}" \
            --ide0 "${SEED_DIR}/desktop-seed.iso,media=cdrom" \
            --scsi0 local-lvm:40,size=40G \
            --boot order=scsi0

        qm start 100
        log "VM 100 (desktop) created and started: ${DESKTOP_MEM}MB, ${DESKTOP_CORES} cores, 40GB OS, MAC 52:54:00:00:01:00"
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

        DATA_VOL_SIZE=500

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
            ${LLM_HOSTPCI:+"$LLM_HOSTPCI"} \
            --cdrom0 "${ISO_DIR}/${UBUNTU_SERVER_ISO}" \
            --ide0 "${SEED_DIR}/llm-seed.iso,media=cdrom" \
            --scsi0 local-lvm:80,size=80G \
            --scsi1 local-lvm:${DATA_VOL_SIZE},size=${DATA_VOL_SIZE}G \
            --boot order=scsi0

        if [ -n "$DGPU_IDS" ]; then
            qm set 101 --args '-cpu host,kvm=off,hidden=1'
            log "Applied GeForce kvm=off,hidden=1 workaround"
        fi

        qm start 101
        log "VM 101 (llm) created and started: ${LLM_MEM}MB, ${LLM_CORES} cores, 80GB OS, ${DATA_VOL_SIZE}GB data"
    else
        log "VM 101 already exists — skipping"
    fi

    # --- VM 102: Dev template (provisioned once, then converted to template) ---
    if ! qm status 102 >/dev/null 2>&1; then
        if qm config 102 2>/dev/null | grep -q "^template:"; then
            log "VM 102 already exists as template — skipping"
        else
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
                --cdrom0 "${ISO_DIR}/${UBUNTU_SERVER_ISO}" \
                --ide0 "${SEED_DIR}/dev-seed.iso,media=cdrom" \
                --scsi0 local-lvm:40,size=40G \
                --boot order=scsi0

            qm start 102
            log "VM 102 (dev-template) created and starting for provisioning: ${DEV_MEM}MB, ${DEV_CORES} cores, 40GB OS"

            PROVISIONING_TIMEOUT=600
            elapsed=0
            log "Provisioning gate: waiting for VM 102 first-boot (timeout: ${PROVISIONING_TIMEOUT}s)"
            while [ $elapsed -lt $PROVISIONING_TIMEOUT ]; do
                if qm guest exec 102 -- test -f /var/log/dev-firstboot.log >/dev/null 2>&1; then
                    if qm guest exec 102 -- grep -q "dev first-boot complete" /var/log/dev-firstboot.log >/dev/null 2>&1; then
                        log "VM 102 first-boot complete"
                        break
                    fi
                fi
                sleep 10
                elapsed=$((elapsed + 10))
                if [ $((elapsed % 60)) -eq 0 ]; then
                    log "Provisioning gate: ${elapsed}s elapsed..."
                fi
            done

            if [ $elapsed -ge $PROVISIONING_TIMEOUT ]; then
                log "WARNING: VM 102 provisioning timed out after ${PROVISIONING_TIMEOUT}s"
                log "  Complete provisioning manually, then run:"
                log "  qm guest exec 102 -- cloud-init clean"
                log "  qm shutdown 102"
                log "  qm template 102"
            else
                qm guest exec 102 -- cloud-init clean 2>/dev/null || true
                qm guest exec 102 -- /bin/bash -c 'truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_*' 2>/dev/null || true
                log "VM 102 identity cleaned for future clones"

                qm shutdown 102 2>/dev/null || true
                sleep 5
                SHUTDOWN_WAIT=0
                while qm status 102 2>/dev/null | grep -q "running"; do
                    sleep 2
                    SHUTDOWN_WAIT=$((SHUTDOWN_WAIT + 2))
                    if [ $SHUTDOWN_WAIT -ge 60 ]; then
                        log "WARNING: VM 102 shutdown timed out, force-stopping"
                        qm stop 102 2>/dev/null || true
                        sleep 3
                        break
                    fi
                done
                qm template 102
                log "VM 102 converted to template (never auto-started)"
            fi
        fi
    else
        log "VM 102 already exists — skipping"
    fi

    log "=== Guest VM creation complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
