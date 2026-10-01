#!/usr/bin/env bash
# frag/30-create-guests.sh — Create Desktop (100), LLM (101), Dev Template (102)
# NoCloud seeds: fetches user-data templates from GitHub, injects password hash
# (+ vmctl and guest-identity private keys for desktop, + admin and guest-identity
# public keys for every guest), builds seed ISOs, creates VMs with official
# Ubuntu ISO + NoCloud seed. Desktop and LLM are started immediately.
# Staged private keys are shredded once every seed is built.
# Dev template (102) is provisioned once then converted to PVE template.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"
# /proc is a kernel interface, not a provisioner output. Overridable for the
# end-to-end test, which supplies a fixture meminfo.
PROC="${PVE_PROC:-/proc}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }
die() { log "FATAL: $*"; exit 1; }

# --- Pure functions (testable via source-guard) ---

partition_passthrough_devices() {
    # Splits frag/10's accepted device set by role: integrated GPUs go to the
    # desktop, discrete NVIDIA GPUs go to the LLM guest. Sets IGPU_IDS and
    # DGPU_IDS as comma-joined full BDFs. A device of unrecognized vendor is
    # left to the host with a warning rather than attached to a guest whose
    # configuration was built around a different device class.
    #
    # Always exits 0: main() calls this as a bare statement under `set -e`,
    # and the while loop below would otherwise return the status of whatever
    # its last iteration happened to run.
    local list_path="$1"
    [ -s "$list_path" ] \
        || die "passthrough device list is missing or empty at ${list_path} (frag/10 did not run or accepted nothing)"

    IGPU_IDS=""
    DGPU_IDS=""
    local full_bdf short_bdf vd vendor
    while IFS= read -r full_bdf; do
        [ -n "$full_bdf" ] || continue
        short_bdf="${full_bdf#0000:}"
        vd=$(lspci -n -s "$short_bdf" | awk '{print $3}')
        vendor="${vd%%:*}"
        case "$vendor" in
            8086|1002)
                IGPU_IDS="${IGPU_IDS:+${IGPU_IDS},}${full_bdf}" ;;
            10de)
                DGPU_IDS="${DGPU_IDS:+${DGPU_IDS},}${full_bdf}" ;;
            *)
                log "WARNING: accepted device ${full_bdf} has unrecognized vendor '${vendor}'; leaving it to the host" ;;
        esac
    done < "$list_path"
    return 0
}

download_iso() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        log "ISO already present: $(basename "$dest")"
        return
    fi
    log "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url" 2>&1 | tee -a "${ROOT}/var/log/pve-firstboot.log"
    log "Downloaded: $(sha256sum "$dest" | awk '{print $1}')"
}

# --- Prerequisites -------------------------------------------------------
#
# All three guests are created inside one `set -euo pipefail` main(), so a
# single failing `qm create` aborts the fragment and leaves the host with zero
# VMs and a log whose last useful line is a `qm` error most operators do not
# read. These checks name the missing prerequisite instead.
#
# Nothing here guesses at hardware. The installer is configured with
# `source = "from-dhcp"`, which gives the host a working address but not
# necessarily a Linux bridge, and picking a physical NIC automatically would be
# the same class of mistake as the disk probe R-01.4.1 prohibits: it can take
# the host's only network path down. So a missing bridge is reported, not
# improvised.

preflight_guest_prerequisites() {
    local bridge="$1" storage="$2"
    local failed=0

    if ! ip link show "$bridge" >/dev/null 2>&1; then
        log "ERROR: bridge '$bridge' does not exist on this host."
        log "  Every guest is created with --net0 ...,bridge=${bridge}, so qm create will"
        log "  reject all three and this fragment will abort before creating any VM."
        log "  The installer's 'source = \"from-dhcp\"' setting does not create a bridge."
        log "  Create it for the NIC you actually want to bridge, then re-run:"
        log "    qm start 0; pvesh get /nodes/$(hostname)/network --output-format json"
        log "    pvesh create /nodes/$(hostname)/network --name ${bridge} --type bridge"
        failed=1
    fi

    if ! pvesm status --storage "$storage" >/dev/null 2>&1; then
        log "ERROR: storage '${storage}' is not available on this host."
        log "  Guests allocate their disks from ${storage} (--scsi0 ${storage}:...,size=...)."
        log "  Check what the installer created with: pvesm status"
        failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        die "guest prerequisites are not met — refusing to start creating VMs"
    fi
    log "Guest prerequisites OK: bridge=${bridge}, storage=${storage}"
}

# --- Main execution (guarded for source-testability) ---

main() {
    # --- Source shared personalization (§05) ---
    # resolve_ref_to_sha comes from here too: it is the single definition, and
    # it never fails (empty string when git or the network is unavailable),
    # which matters under this script's `set -euo pipefail`.
    . "${ROOT}/root/provision/personalization.sh" 2>/dev/null || true
    GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
    GITHUB_REF="${PERSONALIZATION_REF:-main}"
    command -v resolve_ref_to_sha >/dev/null 2>&1 \
        || die "personalization.sh did not provide resolve_ref_to_sha"

    REF_SHA=$(resolve_ref_to_sha "${GITHUB_REPO}" "${GITHUB_REF}")
    if [ -n "$REF_SHA" ]; then
        log "GitHub REF resolved: ${GITHUB_REF} -> ${REF_SHA:0:12}"
    else
        log "WARNING: Could not resolve REF '${GITHUB_REF}' — proceeding with branch name only"
    fi

    GITHUB_BASE_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"

    log "=== Guest VM creation ==="

    # --- Source Ubuntu release config ---
    . "${ROOT}/root/provision/ubuntu-release.conf" 2>/dev/null || {
        UBUNTU_VERSION="26.04"
        UBUNTU_CODENAME="noble"
    }
    UBUNTU_BASE_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}"
    UBUNTU_DESKTOP_ISO="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
    UBUNTU_SERVER_ISO="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

    # --- Detect host resources ---
    TOTAL_MEM_KB=$(awk '/MemTotal/{print $2}' "${PROC}/meminfo")
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    CPU_CORES=$(nproc)
    FREE_DISK_GB=$(df -BG --output=avail "${ROOT}/var/lib/vz" | tail -1 | tr -d ' G')

    log "Host: ${TOTAL_MEM_GB} GB RAM, ${CPU_CORES} cores, ${FREE_DISK_GB} GB free"

    # --- Bridge and storage, single-sourced ---
    # The preflight below checks these names, so they must be the same strings
    # the qm create calls use. Declared once and interpolated everywhere,
    # otherwise the check can pass against a bridge no guest actually uses.
    GUEST_BRIDGE="vmbr0"
    GUEST_STORAGE="local-lvm"

    # Checked before the ISO downloads, which take several minutes, so a host
    # that cannot create a guest says so immediately rather than after a
    # long download followed by an opaque qm error.
    preflight_guest_prerequisites "$GUEST_BRIDGE" "$GUEST_STORAGE"

    # --- Attach exactly the devices frag/10 accepted ---
    #
    # The passthrough decision lives in frag/10, which writes the accepted set
    # to passthrough-devices. This fragment reads that set and partitions it by
    # role — integrated GPU to the desktop, discrete GPUs to the LLM guest — but
    # it never adds a device of its own. A device frag/10 judged unsafe is left
    # to the host even when it is physically present: attaching it anyway would
    # hand the guest hardware the kernel never bound to vfio-pci.
    #
    # A missing or empty set is fatal rather than an empty attachment. An empty
    # `--hostpci` is a silent downgrade: the guest is created, boots, and has no
    # GPU, and nothing in the log explains it.
    PASSTHROUGH_LIST="${ROOT}/var/lib/pve-firstboot/passthrough-devices"
    partition_passthrough_devices "$PASSTHROUGH_LIST"

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

    # --- Read personalization password hash ---
    # This is the LOGIN password for the personalization account in every
    # guest. It is not the host root password, which never leaves the host and
    # is not persisted anywhere the provisioner can read.
    PERSONALIZATION_HASH_FILE="${ROOT}/root/.personalization-password-hash"
    [ -f "$PERSONALIZATION_HASH_FILE" ] \
        || die "Personalization password hash not found: ${PERSONALIZATION_HASH_FILE}"
    PERSONALIZATION_HASH="$(cat "$PERSONALIZATION_HASH_FILE")"
    log "Personalization password hash loaded"

    # --- Read admin public key (build machine operator key) ---
    # Preserved into the provision tree by first-boot.sh. Injected as an
    # authorized key on the host (already, via the PVE answer root-ssh-keys)
    # and on every guest, so the operator key works everywhere.
    ADMIN_PUBKEY_FILE="${ROOT}/root/provision/keys/host_os_ed25519.pub"
    [ -f "$ADMIN_PUBKEY_FILE" ] || die "Admin public key not found: ${ADMIN_PUBKEY_FILE}"
    ADMIN_PUBKEY="$(cat "$ADMIN_PUBKEY_FILE")"
    log "Admin public key loaded for guest injection"

    # --- Read guest identity public key (desktop's install-time identity) ---
    GUEST_ID_PUBKEY_FILE="${ROOT}/root/.nested-dev/guest-id/guest_id_ed25519.pub"
    [ -f "$GUEST_ID_PUBKEY_FILE" ] || die "Guest identity public key not found: ${GUEST_ID_PUBKEY_FILE}"
    GUEST_ID_PUBKEY="$(cat "$GUEST_ID_PUBKEY_FILE")"
    log "Guest identity public key loaded for guest injection"

    # --- Read vmctl private key (base64 for desktop injection) ---
    VMCTL_KEY_FILE="${ROOT}/root/.nested-dev/vmctl-priv-staged"
    [ -f "$VMCTL_KEY_FILE" ] || die "vmctl private key not staged at ${VMCTL_KEY_FILE} (frag/25 did not run?)"
    VMCTL_KEY_B64=$(base64 -w0 "$VMCTL_KEY_FILE" 2>/dev/null || base64 "$VMCTL_KEY_FILE" 2>/dev/null)
    log "vmctl private key loaded for desktop seed injection"

    # --- Read guest identity private key (base64 for desktop injection) ---
    GUEST_ID_KEY_FILE="${ROOT}/root/.nested-dev/guest-id-priv-staged"
    [ -f "$GUEST_ID_KEY_FILE" ] || die "Guest identity private key not staged at ${GUEST_ID_KEY_FILE} (frag/25 did not run?)"
    GUEST_ID_KEY_B64=$(base64 -w0 "$GUEST_ID_KEY_FILE" 2>/dev/null || base64 "$GUEST_ID_KEY_FILE" 2>/dev/null)
    log "Guest identity private key loaded for desktop seed injection"

    # --- Create NoCloud seed directory ---
    SEED_DIR="${ROOT}/var/lib/vz/template/cidata"
    mkdir -p "$SEED_DIR"

    # --- Install genisoimage if needed ---
    if ! command -v genisoimage >/dev/null 2>&1; then
        log "Installing genisoimage..."
        apt-get update -qq 2>/dev/null
        apt-get install -y genisoimage 2>&1 | tail -1 >> "${ROOT}/var/log/pve-firstboot.log"
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

        for required in PERSONALIZATION_USERNAME PERSONALIZATION_FULLNAME \
                       PERSONALIZATION_UID PERSONALIZATION_GID; do
            if [ -z "${!required:-}" ]; then
                die "${required} not set — check ${ROOT}/root/provision/personalization.sh"
            fi
        done
        sed -e "s|CHANGE_ME_HASHED|${PERSONALIZATION_HASH}|g" \
            -e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g" \
            -e "s|__GUEST_ID_PRIV_B64__|${GUEST_ID_KEY_B64}|g" \
            -e "s|__ADMIN_PUBKEY__|${ADMIN_PUBKEY}|g" \
            -e "s|__GUEST_ID_PUBKEY__|${GUEST_ID_PUBKEY}|g" \
            -e "s|__PERSONALIZATION_USERNAME__|${PERSONALIZATION_USERNAME}|g" \
            -e "s|__PERSONALIZATION_FULLNAME__|${PERSONALIZATION_FULLNAME}|g" \
            -e "s|__PERSONALIZATION_UID__|${PERSONALIZATION_UID}|g" \
            -e "s|__PERSONALIZATION_GID__|${PERSONALIZATION_GID}|g" \
            -e "s|__GITHUB_REF__|${REF_SHA:-$GITHUB_REF}|g" \
            "${SEED_DIR}/${guest}-template" > "$SEED_FILE"

        # A surviving placeholder means a substitution silently failed and the
        # guest would boot without the key. Fail here rather than at runtime.
        if grep -q '__[A-Z_]*__' "$SEED_FILE"; then
            die "Unsubstituted placeholders left in ${guest} seed: $(grep -o '__[A-Z_]*__' "$SEED_FILE" | sort -u | tr '\n' ' ')"
        fi

        echo "instance-id: ${guest}-$(date +%s)" > "${SEED_DIR}/${guest}-meta-data"

        genisoimage -r -V cidata -joliet-long -o "${SEED_DIR}/${guest}-seed.iso" \
            "$SEED_FILE" "${SEED_DIR}/${guest}-meta-data" 2>/dev/null

        log "NoCloud seed prepared: ${guest}"
    done

    # --- Destroy the staged private halves ---
    # Every seed now carries both private keys, so the staging copies have
    # served their purpose. The canonical copies under /root/.nested-dev/ are
    # kept (600, root-only) so a re-provision stays idempotent; frag/25
    # re-stages on every run.
    for staged in "$VMCTL_KEY_FILE" "$GUEST_ID_KEY_FILE"; do
        if shred -u "$staged" 2>/dev/null || rm -f "$staged"; then
            log "Staged private key shredded: ${staged}"
        else
            die "Failed to remove staged private key: ${staged}"
        fi
    done

    # --- Download Ubuntu ISOs if not present ---
    ISO_DIR="${ROOT}/var/lib/vz/template/iso"
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
            --net0 virtio=52:54:00:00:01:00,bridge=${GUEST_BRIDGE} \
            --ostype l26 \
            --bios ovmf \
            --machine q35 \
            --vga none \
            --serial0 socket \
            --agent enabled=1 \
            ${DESKTOP_HOSTPCI:+"$DESKTOP_HOSTPCI"} \
            --cdrom0 "${ISO_DIR}/${UBUNTU_DESKTOP_ISO}" \
            --ide0 "${SEED_DIR}/desktop-seed.iso,media=cdrom" \
            --scsi0 ${GUEST_STORAGE}:40,size=40G \
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
            --net0 virtio=52:54:00:00:01:01,bridge=${GUEST_BRIDGE} \
            --ostype l26 \
            --bios ovmf \
            --machine q35 \
            --vga none \
            --serial0 socket \
            --agent enabled=1 \
            ${LLM_HOSTPCI:+"$LLM_HOSTPCI"} \
            --cdrom0 "${ISO_DIR}/${UBUNTU_SERVER_ISO}" \
            --ide0 "${SEED_DIR}/llm-seed.iso,media=cdrom" \
            --scsi0 ${GUEST_STORAGE}:80,size=80G \
            --scsi1 ${GUEST_STORAGE}:${DATA_VOL_SIZE},size=${DATA_VOL_SIZE}G \
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
                --net0 virtio=52:54:00:00:01:02,bridge=${GUEST_BRIDGE},firewall=1 \
                --ostype l26 \
                --bios ovmf \
                --machine q35 \
                --vga none \
                --serial0 socket \
                --agent enabled=1 \
                --cdrom0 "${ISO_DIR}/${UBUNTU_SERVER_ISO}" \
                --ide0 "${SEED_DIR}/dev-seed.iso,media=cdrom" \
                --scsi0 ${GUEST_STORAGE}:40,size=40G \
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
