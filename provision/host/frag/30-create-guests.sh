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

cap_vm_cores() {
    # The profile's core count bounded by what the node allows per VM. Prints
    # the smaller of the want and the host's core count (floor 1), and logs
    # when the profile is cut down, so a 4-core host running the 6-core LLM
    # profile says so instead of failing the create opaquely.
    local want="$1" max="$CPU_CORES"
    [ "$max" -ge 1 ] 2>/dev/null || max=1
    if [ "$want" -gt "$max" ]; then
        log "host allows ${max} vcpus per VM; capping allocation from ${want} to ${max}"
        want="$max"
    fi
    printf '%s\n' "$want"
}

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

hostpci_device_arg() {
    # The qm device string for one passed-through PCI function. Option ROMs
    # stay off: OVMF executes them at boot, consumer GOP takes the physical
    # heads (invisible on the emulated console) and on this hardware never
    # returns — a guest vCPU pegged at 100% with zero disk I/O and blank
    # consoles. The proprietary driver initializes the card itself later.
    # Passthrough bring-up failure modes, in the order to check them:
    # blank consoles + pegged vCPU + zero disk I/O = firmware loop (this
    # flag); FLR warnings at start = cosmetic on FLR-less silicon, but a
    # stopped-then-started guest may need a host reboot to clear device
    # state; driver refusing in-guest = the kvm=off hiding, not the attach.
    printf 'host=%s,pcie=1,rombar=0\n' "$1"
}
# that never partitioned has no ESP, and detaching the installer onto it
# strands the guest at a UEFI shell. Read from the partition table itself
# with sfdisk -d, matched by EITHER EFI GUID: fdisk aliases both to "EFI
# System", curtin writes C12A7328 (not the textbook C12A4738), and OVMF boots
# it — proven by a booted test-clone. Matching one GUID failed a completed
# install with a populated ESP.
EFI_PARTTYPES="c12a4738-f02b-4b93-8fd5-043ef0e62c58|c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
os_esp() {
    local vmid="$1" dev
    # Unquoted by intent: the default is a glob, the override a list.
    # shellcheck disable=SC2086
    for dev in ${VM_DISK_DEVS:-/dev/pve/vm-${vmid}-disk-1 /dev/mapper/*vm--${vmid}--disk--1}; do
        [ -e "$dev" ] || continue
        if sfdisk -d "$dev" 2>/dev/null | grep -qiE "${EFI_PARTTYPES}"; then
            printf '%s\n' "$dev"
            return 0
        fi
    done
    return 1
}

# Install serial capture, started right after `qm start` while the installer
# is still booting. socat on a not-yet-existing socket dies instantly (so a
# bare call races QEMU socket creation and usually loses — the empty file
# with nothing in it), hence the retry loop: early oopses land ~2 min in,
# the window is 5 min, and a slow start burns retries, never the capture.
# Stale readers are killed first (a previous failed run's orphan would split
# the stream). The socket takes one client: `qm terminal` holds it
# exclusively, so during runs watch the FILE, never the terminal — attaching
# both starves the capture while looking perfectly healthy. Stopped once the
# install powers off; killed explicitly on die paths too, so at most one
# reader ever exists. No socat on PATH means no capture, warned once, never
# fatal — that is also the e2e posture.
# Time-only seams for tests (production defaults).
SERIAL_CAP_PID=""
start_serial_capture() {
    local vmid="$1"
    if ! command -v socat >/dev/null 2>&1; then
        log "WARNING: socat unavailable — serial install log for VM ${vmid} will not be captured"
        return 0
    fi
    pkill -f "socat.*qemu-server/${vmid}\.serial" 2>/dev/null || true
    # The socket carries the device index (serial0 socket -> 101.serial0),
    # unlike qga/qmp which have fixed names — a bare .serial never exists.
    local sock="/var/run/qemu-server/${vmid}.serial0"
    local caplog="${ROOT}/var/log/pve-serial-${vmid}-install.log"
    : > "$caplog"
    (
        local attempt=0
        local max="${SERIAL_RETRY_MAX:-60}" interval="${SERIAL_RETRY_INTERVAL:-5}"
        while [ "$attempt" -lt "$max" ]; do
            if socat -u "UNIX-CONNECT:${sock}" "OPEN:${caplog},creat,append" >/dev/null 2>&1; then
                exit 0
            fi
            sleep "$interval"
            attempt=$((attempt + 1))
        done
        log "WARNING: serial capture never connected for VM ${vmid}"
    ) &
    SERIAL_CAP_PID=$!
    log "serial capture started for VM ${vmid} -> ${caplog}"
}
stop_serial_capture() {
    local vmid="$1"
    [ -n "${SERIAL_CAP_PID:-}" ] || return 0
    kill "$SERIAL_CAP_PID" 2>/dev/null || true
    pkill -f "socat.*qemu-server/${vmid}\.serial" 2>/dev/null || true
    wait "$SERIAL_CAP_PID" 2>/dev/null || true
    log "serial capture stopped"
    SERIAL_CAP_PID=""
}

# Install-completion waits, shared by all three guests (defined beside the
# pure functions because VM 100 uses them before VM 101's section would
# define them — a later definition reads as a timeout at the call site).
wait_for_stopped() {
    # A parked stopped VM is end-of-run: server seeds end the install
    # powered off. A mid-install reboot keeps the VM running and never
    # trips this wait.
    local vmid="$1" timeout="$2" elapsed=0
    while qm status "$vmid" 2>/dev/null | grep -q "running"; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
    done
    return 0
}
wait_for_agent() {
    # Only a booted system (agent answering) counts as installed afterward;
    # detaching onto an unbootable disk strands the guest at a UEFI shell.
    local vmid="$1" timeout="$2" elapsed=0
    while ! qm agent "$vmid" ping >/dev/null 2>&1; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
    done
    return 0
}

download_iso() {
    local url="$1" dest="$2"
    if [ -f "$dest" ]; then
        log "ISO already present: $(basename "$dest")"
        return 0
    fi
    log "Downloading $(basename "$dest")..."
    wget -q --show-progress -O "$dest" "$url" 2>&1 | tee -a "${ROOT}/var/log/pve-firstboot.log"
    log "Downloaded: $(sha256sum "$dest" | awk '{print $1}')"
}

# --- Rack input detection (R-02.2.7) ---------------------------------------
# Physical keyboard/mouse by-id paths for VM 100 evdev routing. The directory
# is a parameter (default: the live tree) so tests exercise this against
# fixtures instead of the provision host's own devices. Never fatal: a
# headless host has no by-id input links, and then the guest keeps VNC-only
# input. Environment overrides win over detection (operators, e2e).
detect_rack_keyboard() {
    local dir="${1:-/dev/input/by-id}" link
    [ -d "$dir" ] || return 1
    # Prefer the main keyboard interface; secondary USB interfaces (media
    # keys, e.g. *-if01-event-kbd) are not the typing keyboard.
    for link in "$dir"/*-event-kbd; do
        [ -L "$link" ] || continue
        case "${link##*/}" in
            *-if[0-9]*-*) continue ;;
        esac
        printf '%s\n' "$link"
        return 0
    done
    for link in "$dir"/*-event-kbd; do
        [ -L "$link" ] || continue
        printf '%s\n' "$link"
        return 0
    done
    return 1
}

detect_rack_mouse() {
    local dir="${1:-/dev/input/by-id}" link
    [ -d "$dir" ] || return 1
    # The evdev node (-event-mouse), never the legacy mousedev joint (-mouse).
    for link in "$dir"/*-event-mouse; do
        [ -L "$link" ] || continue
        printf '%s\n' "$link"
        return 0
    done
    return 1
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
    # Pinned like ubuntu-release.conf (see it for why): point releases are
    # discrete decisions, and this fallback must resolve the same files.
    UBUNTU_DESKTOP_ISO="ubuntu-26.04.1-desktop-amd64.iso"
    UBUNTU_SERVER_ISO="ubuntu-26.04.1-live-server-amd64.iso"

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

    # PVE 9 refuses a VM whose vCPU count exceeds the node's per-VM maximum,
    # which tracks the host's visible cores: requesting 6 on a 4-core host
    # fails the create with "MAX 4 vcpus allowed per VM on this node". Cap
    # each guest at what the node allows rather than what the profile wants.
    DESKTOP_CORES=$(cap_vm_cores "$DESKTOP_CORES")
    LLM_CORES=$(cap_vm_cores "$LLM_CORES")
    DEV_CORES=$(cap_vm_cores "$DEV_CORES")

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
    # User-data, meta-data and templates live here. The seed *ISOs* go to
    # ISO_DIR instead: PVE verifies every drive path against its storages, and
    # template/iso/ is the `local` storage's iso content path while
    # template/cidata/ belongs to no storage — a seed ISO built here is
    # rejected with "unable to associate path to any storage".
    SEED_DIR="${ROOT}/var/lib/vz/template/cidata"
    mkdir -p "$SEED_DIR"
    ISO_DIR="${ROOT}/var/lib/vz/template/iso"
    mkdir -p "$ISO_DIR"

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

        # NoCloud discovers exactly `user-data` and `meta-data` at the ISO
        # root. Passing the files bare bakes them in under their on-disk
        # basenames (`desktop-user-data`), which cloud-init ignores — the
        # installer then goes interactive and waits forever while the
        # provisioning gate times out on a guest that never started. The
        # graft maps each file to the name the datasource looks for.
        genisoimage -r -V cidata -joliet-long -o "${ISO_DIR}/${guest}-seed.iso" \
            -graft-points "user-data=${SEED_FILE}" "meta-data=${SEED_DIR}/${guest}-meta-data" \
            2>/dev/null

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
    # ISO_DIR is defined and created beside SEED_DIR above, because the seed
    # ISOs are built there too.
    download_iso "${UBUNTU_BASE_URL}/${UBUNTU_DESKTOP_ISO}" "${ISO_DIR}/${UBUNTU_DESKTOP_ISO}"
    download_iso "${UBUNTU_BASE_URL}/${UBUNTU_SERVER_ISO}" "${ISO_DIR}/${UBUNTU_SERVER_ISO}"

    # --- Extract installer kernels for QEMU direct boot ---
    # Stock ISOs boot without the `autoinstall` flag, so the installer waits
    # on its yes/no prompt forever. The ISOs' own kernel+initrd boot directly
    # with a host-owned command line (R-01.11.13); each ISO stays attached as
    # its own package source. Desktop included: its seed is Subiquity-valid
    # and the wallpaper-sit was the same missing flag, never proof otherwise.
    EXTRACT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/extract-installer-kernel.sh"
    SERVER_BASE="${UBUNTU_SERVER_ISO%.iso}"
    APPEND_ARGS="$(bash "$EXTRACT_SCRIPT" "${ISO_DIR}/${UBUNTU_SERVER_ISO}" "${ISO_DIR}")" \
        || die "installer kernel extraction failed"
    SERVER_KERNEL="${ISO_DIR}/${SERVER_BASE}-vmlinuz"
    SERVER_INITRD="${ISO_DIR}/${SERVER_BASE}-initrd"
    QEMU_APPEND="${APPEND_ARGS:+$APPEND_ARGS }autoinstall console=ttyS0 console=tty0"
    log "installer direct boot ready: ${SERVER_BASE} + autoinstall"
    log "installer boot args: ${QEMU_APPEND}"
    DESKTOP_BASE="${UBUNTU_DESKTOP_ISO%.iso}"
    DESKTOP_APPEND_ARGS="$(bash "$EXTRACT_SCRIPT" "${ISO_DIR}/${UBUNTU_DESKTOP_ISO}" "${ISO_DIR}")" \
        || die "desktop installer kernel extraction failed"
    DESKTOP_KERNEL="${ISO_DIR}/${DESKTOP_BASE}-vmlinuz"
    DESKTOP_INITRD="${ISO_DIR}/${DESKTOP_BASE}-initrd"
    DESKTOP_QEMU_APPEND="${DESKTOP_APPEND_ARGS:+$DESKTOP_APPEND_ARGS }autoinstall console=ttyS0 console=tty0"
    log "desktop direct boot ready: ${DESKTOP_BASE} + autoinstall"
    # Console order matters: kernel messages go to both, /dev/console (and
    # the installer TUI) stays on VGA via the last entry, while the serial
    # carries everything for host-side capture (qm terminal). A guest oops
    # is otherwise readable only off VNC glass, unscrollable and uncopyable.

    # --- VM 100: Desktop ---
    # Boot order names the installer explicitly: PVE passes strict=on, so an
    # order naming only the empty disk parks the guest at a UEFI shell instead
    # of falling through to the CDROM. The installer ISO is detached after
    # each guest's first boot completes, so a post-install reboot lands in the
    # installed system rather than looping back into the installer.
    #
    # No emulated display: the passed-through iGPU is this guest's console
    # (R-02.3.4), and a second GPU would muddy which head is primary. The
    # server guests below keep one: headless fleet VMs gain nothing from it
    # day to day, but every blind debugging session on this project has cost
    # hours for want of a console, and an emulated VGA costs essentially
    # nothing to carry.
    if ! qm status 100 >/dev/null 2>&1; then
        # An array, not a string: "--hostpci0 <value>" built as one string and
        # expanded quoted arrives at qm as a single glued argument, which PVE 9
        # rejects with "Unknown option: hostpci0 ...". Each element below is
        # one argv word. The empty-array expansion is zero words, so a guest
        # with no passthrough hardware gets no hostpci flag at all rather than
        # an empty one.
        DESKTOP_HOSTPCI=()
        if [ -n "$IGPU_IDS" ]; then
            DESKTOP_HOSTPCI=(--hostpci0 "host=${IGPU_IDS},pcie=1,x-vga=0")
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
            ${DESKTOP_HOSTPCI[@]+"${DESKTOP_HOSTPCI[@]}"} \
            --ide2 "${ISO_DIR}/${UBUNTU_DESKTOP_ISO},media=cdrom" \
            --ide0 "${ISO_DIR}/desktop-seed.iso,media=cdrom" \
            --efidisk0 ${GUEST_STORAGE}:1 \
            --scsi0 ${GUEST_STORAGE}:40 \
            --boot "order=ide2;scsi0"

        qm set 100 --args "-kernel ${DESKTOP_KERNEL} -initrd ${DESKTOP_INITRD} -append '${DESKTOP_QEMU_APPEND}'"
        log "VM 100 direct-kernel boot configured (autoinstall, no prompt)"
        qm start 100
        log "VM 100 (desktop) created and started: ${DESKTOP_MEM}MB, ${DESKTOP_CORES} cores, 40GB OS, MAC 52:54:00:00:01:00"
        start_serial_capture 100
        log "Install gate: waiting for VM 100 to power off at end of install (timeout: 1800s)"
        if ! wait_for_stopped 100 1800; then
            stop_serial_capture 100
            die "VM 100 install did not finish in 1800s — install serial log at ${ROOT}/var/log/pve-serial-100-install.log; inspect its console"
        fi
        stop_serial_capture 100
        if [ -z "$(os_esp 100)" ]; then
            qm set 100 --delete args 2>/dev/null || true
            die "VM 100 has no EFI partition on its OS disk — install failed before partitioning; installer media left attached for forensics"
        fi
        qm set 100 --delete ide2 --boot "order=scsi0"
        qm set 100 --delete args
        log "VM 100 installer detached; booting installed system"
        # --- VM 100: rack input routing (R-02.2.7) ---
        # evdev passthrough with operator grab-toggle, set while stopped so it
        # applies at the start below. repeat=off keeps the guest X server the
        # single repeat owner (R-02.2.6): host-kernel repeats would arrive as
        # extra presses on top of it. Absent devices keep VNC-only input and
        # never fail provisioning.
        RACK_KBD_EVIDEV="${RACK_KBD_EVIDEV:-$(detect_rack_keyboard || true)}"
        RACK_MOUSE_EVIDEV="${RACK_MOUSE_EVIDEV:-$(detect_rack_mouse || true)}"
        if [ -n "$RACK_KBD_EVIDEV" ] && [ -n "$RACK_MOUSE_EVIDEV" ]; then
            # Two hard-won pairings, both observed live. Devices: virtio-mouse
            # (relative), NOT virtio-tablet — a physical mouse emits REL
            # events and the input core routes those to relative devices
            # only, so on a tablet motion drops while clicks survive.
            # grab_all ONLY on the keyboard: QEMU's group propagation skips
            # every object carrying grab_all (endless-loop guard), so a mouse
            # object with grab_all never follows the toggle and stays grabbed
            # while the keyboard flips. The toggle chord is only visible on
            # the keyboard's evdev anyway.
            qm set 100 --args "-object input-linux,id=rkbd,evdev=${RACK_KBD_EVIDEV},grab_all=on,repeat=off,grab-toggle=ctrl-ctrl -object input-linux,id=rmouse,evdev=${RACK_MOUSE_EVIDEV} -device virtio-keyboard-pci,id=rkbd-dev -device virtio-mouse-pci,id=rmouse-dev"
            log "VM 100 rack input attached (ctrl-ctrl toggles host/guest): kbd=${RACK_KBD_EVIDEV} mouse=${RACK_MOUSE_EVIDEV}"
        else
            log "WARNING: no rack keyboard/mouse detected — VM 100 keeps VNC-only input"
        fi
        qm start 100
        log "Waiting for VM 100 installed system to answer (timeout: 600s)"
        if ! wait_for_agent 100 600; then
            die "VM 100 installed system never answered — reattach the installer with: qm set 100 --ide2 ${ISO_DIR}/${UBUNTU_DESKTOP_ISO},media=cdrom --boot \"order=ide2;scsi0\""
        fi
        log "VM 100 (desktop) installed system booting; first-boot proceeds unattended"
    else
        log "VM 100 already exists — skipping"
    fi

    # --- VM 101: LLM ---
    # Server seeds end the install powered off (shutdown: poweroff): a parked
    # stopped VM is the completion signal, unambiguous where a reboot would
    # re-enter the installer under ide2-first order. A mid-install reboot
    # keeps the VM running and never trips this wait.
    if ! qm status 101 >/dev/null 2>&1; then
        # Install with the OS disk alone. With two data disks the installer's
        # default layout picks the largest — it took the 500GB data volume
        # over the 80GB OS disk, booting to a UEFI shell off the empty one.
        # Passthrough GPUs stay off for the same reason: nouveau probes them
        # while they serve nothing before first-boot. Data volume, dGPUs and
        # the GeForce workaround attach after the install powers off, before
        # the installed system boots (first-boot formats vdb itself).
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
            --vga std \
            --serial0 socket \
            --agent enabled=1 \
            --ide2 "${ISO_DIR}/${UBUNTU_SERVER_ISO},media=cdrom" \
            --ide0 "${ISO_DIR}/llm-seed.iso,media=cdrom" \
            --efidisk0 ${GUEST_STORAGE}:1 \
            --scsi0 ${GUEST_STORAGE}:80 \
            --boot "order=ide2;scsi0"

            qm set 101 --args "-kernel ${SERVER_KERNEL} -initrd ${SERVER_INITRD} -append '${QEMU_APPEND}'"
            log "VM 101 direct-kernel boot configured (autoinstall, no prompt)"
            qm start 101
            log "VM 101 (llm) created and started: ${LLM_MEM}MB, ${LLM_CORES} cores, 80GB OS (data and GPUs attach post-install)"
            start_serial_capture 101
            log "Install gate: waiting for VM 101 to power off at end of install (timeout: 1800s)"
            if ! wait_for_stopped 101 1800; then
                stop_serial_capture 101
                die "VM 101 install did not finish in 1800s — install serial log at ${ROOT}/var/log/pve-serial-101-install.log; inspect its console"
            fi
            stop_serial_capture 101
            if [ -z "$(os_esp 101)" ]; then
                # Drop direct-kernel boot first: otherwise every later boot
                # reloads the installer kernel, which cannot find its medium
                # without the grub context (casper netboot prompt) — manual
                # recovery wants the ISO grub path, not another direct boot.
                qm set 101 --delete args 2>/dev/null || true
                die "VM 101 has no EFI partition on its OS disk — install failed before partitioning; installer media left attached for forensics"
            fi
            qm set 101 --scsi1 ${GUEST_STORAGE}:${DATA_VOL_SIZE}
            log "VM 101 data volume attached (${DATA_VOL_SIZE}GB raw for first-boot to format)"
        if [ -n "$DGPU_IDS" ]; then
            LLM_HOSTPCI=()
            DGPU_INDEX=0
            IFS=',' read -ra DGPU_LIST <<< "$DGPU_IDS"
            for dgpu in "${DGPU_LIST[@]}"; do
                LLM_HOSTPCI+=("--hostpci${DGPU_INDEX}" "$(hostpci_device_arg "$dgpu")")
                DGPU_INDEX=$((DGPU_INDEX + 1))
            done
            qm set 101 ${LLM_HOSTPCI[@]+"${LLM_HOSTPCI[@]}"} \
                --args '-cpu host,kvm=off'
            log "Applied dGPU passthrough and GeForce kvm=off workaround (hypervisor hidden from the driver; no FLR on GP104, so a stopped-then-started 101 may need a host reboot to clear device state)"
        else
            qm set 101 --delete args
            log "VM 101 direct-kernel args removed; disk boot from here"
        fi
            qm set 101 --delete ide2 --boot "order=scsi0"
            log "VM 101 installer detached; booting installed system"
            qm start 101
            log "Waiting for VM 101 installed system to answer (timeout: 600s)"
            if ! wait_for_agent 101 600; then
                die "VM 101 installed system never answered — reattach the installer with: qm set 101 --ide2 ${ISO_DIR}/${UBUNTU_SERVER_ISO},media=cdrom --boot \"order=ide2;scsi0\""
            fi
            log "VM 101 (llm) installed system booting; first-boot proceeds unattended"
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
                --vga std \
                --serial0 socket \
                --agent enabled=1 \
                --ide2 "${ISO_DIR}/${UBUNTU_SERVER_ISO},media=cdrom" \
                --ide0 "${ISO_DIR}/dev-seed.iso,media=cdrom" \
                --efidisk0 ${GUEST_STORAGE}:1 \
                --scsi0 ${GUEST_STORAGE}:40 \
                --boot "order=ide2;scsi0"

            qm set 102 --args "-kernel ${SERVER_KERNEL} -initrd ${SERVER_INITRD} -append '${QEMU_APPEND}'"
            log "VM 102 direct-kernel boot configured (autoinstall, no prompt)"
            qm start 102
            log "VM 102 (dev-template) created and starting for provisioning: ${DEV_MEM}MB, ${DEV_CORES} cores, 40GB OS"
            start_serial_capture 102

            PROVISIONING_TIMEOUT=1800
            log "Install gate: waiting for VM 102 to power off at end of install (timeout: ${PROVISIONING_TIMEOUT}s)"
            if ! wait_for_stopped 102 "$PROVISIONING_TIMEOUT"; then
                stop_serial_capture 102
                die "VM 102 install did not finish in ${PROVISIONING_TIMEOUT}s — install serial log at ${ROOT}/var/log/pve-serial-102-install.log; inspect its console"
            fi
            stop_serial_capture 102
            if [ -z "$(os_esp 102)" ]; then
                # Same as 101 above: direct-kernel boot cannot find its medium
                # without grub context, so restore normal ISO boot for manual
                # recovery instead of another direct boot into netboot.
                qm set 102 --delete args 2>/dev/null || true
                die "VM 102 has no EFI partition on its OS disk — install failed before partitioning; installer media left attached for forensics"
            fi
            qm set 102 --delete ide2 --boot "order=scsi0"
            qm set 102 --delete args
            log "VM 102 installer detached and direct-kernel args removed; booting installed system"
            qm start 102
            log "Waiting for VM 102 installed system to answer (timeout: 600s)"
            if ! wait_for_agent 102 600; then
                die "VM 102 installed system never answered — reattach the installer with: qm set 102 --ide2 ${ISO_DIR}/${UBUNTU_SERVER_ISO},media=cdrom --boot \"order=ide2;scsi0\""
            fi
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
                    # Say which phase it is stuck in, if it is stuck: the
                    # installer has no guest agent by design, so silence from
                    # the agent means autoinstall is still running, while an
                    # answering agent with no completion marker means
                    # dev-firstboot.sh (docker install + four image pulls) is
                    # the long pole.
                    if qm agent 102 ping >/dev/null 2>&1; then
                        log "Provisioning gate: ${elapsed}s elapsed... (installed system up, dev-firstboot running)"
                    else
                        log "Provisioning gate: ${elapsed}s elapsed... (installer phase, no agent by design)"
                    fi
                fi
            done

            if [ $elapsed -ge $PROVISIONING_TIMEOUT ]; then
                log "WARNING: VM 102 provisioning timed out after ${PROVISIONING_TIMEOUT}s"
                log "  Complete provisioning manually, then run:"
                log "  qm guest exec 102 -- cloud-init clean"
                log "  qm shutdown 102"
                log "  qm template 102"
            else
                # Sanitize template identity while the VM still runs (guest-exec):
                # everything that must differ per clone is removed here, so no
                # child can impersonate another. The seed ISO detaches below:
                # it carries rendered private keys (vmctl, guest-id) that must
                # never reach a clone. Local extras are never merged back from
                # anywhere; revoking a key means editing the clone, not this.
                qm guest exec 102 -- cloud-init clean --logs 2>/dev/null || true
                qm guest exec 102 -- /bin/bash -c 'truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_* && rm -f /var/lib/systemd/random-seed && rm -f /var/lib/dhcp/*.leases /var/lib/dhcp/*.lease /var/lib/systemd/network/*.lease && rm -rf /var/lib/snapd/device /var/lib/snapd/device.json && rm -f /etc/docker/key.json && truncate -s 0 /root/.bash_history /home/*/.bash_history 2>/dev/null; true' 2>/dev/null || true
                log "VM 102 identity cleaned for future clones (machine-id, ssh keys, seed, leases, snapd device, docker key, histories)"

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
                # Seed ISO detaches last, immediately before conversion: it
                # carries rendered private keys that must never reach a clone,
                # and nothing after the install needs it. Detaching a stopped
                # VM is pure config (no hot-eject involved).
                qm set 102 --delete ide0 2>/dev/null \
                    || die "seed ISO detach failed — refusing to convert a template that carries rendered private keys"
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
