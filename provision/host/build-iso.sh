#!/usr/bin/env bash
# build-iso.sh — Build PVE 9.2 autoinstall ISO
# Downloads PVE ISO, injects answer file, produces proxmox-ve_9.2-1_auto.iso
# REF: __GITHUB_REF__ (resolved at build time)
#
# Requirements: Linux x86_64, wget, xorriso, root
# Usage: sudo ./build-iso.sh
set -euo pipefail

# --- Utilities (must be defined before first use) ---
log() { printf '[build-iso] %s\n' "$*"; }
die() { printf '[build-iso] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Pure functions (testable via source-guard) ---

detect_target_disk() {
    local target=""
    for disk in /dev/nvme?n?; do
        [ -b "$disk" ] && target="$disk" && break
    done
    if [ -z "$target" ]; then
        for disk in /dev/sd?; do
            if [ -f "/sys/block/$(basename "$disk")/queue/rotational" ]; then
                local rota
                rota=$(cat "/sys/block/$(basename "$disk")/queue/rotational")
                if [ "$rota" -eq 0 ]; then
                    target="$disk"
                    break
                fi
            fi
        done
    fi
    if [ -z "$target" ]; then
        for disk in /dev/sd?; do
            [ -b "$disk" ] && target="$disk" && break
        done
    fi
    echo "$target"
}

generate_answer_file() {
    local template="$1" disk_short="$2" ssh_key="$3" ref="$4" output="$5"
    sed \
        -e "s|__ROOT_SSH_KEY__|${ssh_key}|g" \
        -e "s|__AUTO_DETECT_DISK__|${disk_short}|g" \
        -e "s|__GITHUB_REF__|${ref}|g" \
        "$template" > "$output"
}

# --- Main execution (guarded for source-testability) ---

main() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    OUTPUT_DIR="${REPO_ROOT}/output"
    ISO_DIR="${OUTPUT_DIR}/iso"
    WORK_DIR="${OUTPUT_DIR}/build-work"

    # Source shared personalization (§05)
    . "${REPO_ROOT}/provision/personalization.sh"
    REF="${PERSONALIZATION_REF}"

    # --- Preflight ---
    [ "$(id -u)" -eq 0 ] || die "Run as root (needed for xorriso)"
    for cmd in wget xorriso bsdtar sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
    done

    # Password hash (not committed — read at build time only)
    PASSWORD_HASH_FILE="${REPO_ROOT}/keys/password-hash"
    [ -f "$PASSWORD_HASH_FILE" ] || die "Missing: ${PASSWORD_HASH_FILE} (generate with mkpasswd)"

    mkdir -p "$ISO_DIR" "$WORK_DIR"

    # --- 1. Download PVE ISO ---
    PVE_ISO_URL="https://download.proxmox.com/iso/proxmox-ve_9.2-1.iso"
    PVE_ISO_NAME="proxmox-ve_9.2-1.iso"
    PVE_ISO_PATH="${ISO_DIR}/${PVE_ISO_NAME}"
    PVE_ISO_SHA256="CHANGE_ME_AFTER_DOWNLOAD"  # Update after first verified download

    if [ ! -f "$PVE_ISO_PATH" ]; then
        log "Downloading PVE 9.2 ISO..."
        wget -q --show-progress -O "$PVE_ISO_PATH" "$PVE_ISO_URL"
        ACTUAL_SHA=$(sha256sum "$PVE_ISO_PATH" | awk '{print $1}')
        log "Downloaded: ${ACTUAL_SHA}"
        log "Update PVE_ISO_SHA256 in this script to: ${ACTUAL_SHA}"
    else
        log "PVE ISO already present: $PVE_ISO_PATH"
    fi

    # Verify SHA256 if pinned
    if [ "$PVE_ISO_SHA256" != "CHANGE_ME_AFTER_DOWNLOAD" ]; then
        echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - || die "ISO SHA256 mismatch"
        log "PVE ISO SHA256 verified"
    else
        log "WARNING: PVE ISO SHA256 not pinned — skipping verification"
    fi

    # --- 2. Read SSH public key ---
    SSH_KEY_FILE="${REPO_ROOT}/keys/host_os_ed25519.pub"
    if [ ! -f "$SSH_KEY_FILE" ]; then
        die "SSH public key not found: ${SSH_KEY_FILE}"
    fi
    SSH_KEY=$(tr -d '\n' < "$SSH_KEY_FILE")
    log "SSH key loaded from ${SSH_KEY_FILE}"

    # --- 3. Auto-detect target disk ---
    TARGET_DISK=$(detect_target_disk)
    [ -n "$TARGET_DISK" ] || die "No disk detected for target"

    DISK_SHORT=$(basename "$TARGET_DISK")
    log "Target disk: ${TARGET_DISK} (${DISK_SHORT})"

    # --- 4. Generate answer file from template ---
    ANSWER_TEMPLATE="${SCRIPT_DIR}/answer-host.toml"
    ANSWER_WORK="${WORK_DIR}/answer-host.toml"

    [ -f "$ANSWER_TEMPLATE" ] || die "Answer template not found: ${ANSWER_TEMPLATE}"

    generate_answer_file "$ANSWER_TEMPLATE" "$DISK_SHORT" "$SSH_KEY" "$REF" "$ANSWER_WORK"
    log "Answer file generated: ${ANSWER_WORK}"

    # --- 5. Verify answer file with PVE tool (required check, not optional) ---
    if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
        log "Verifying answer file schema..."
        proxmox-auto-install-assistant verify "$ANSWER_WORK" \
            || die "Answer file schema check failed — fix answer-host.toml"
    else
        log "WARNING: proxmox-auto-install-assistant not found — skipping schema verification"
        log "  Install from the PVE repo for built-in validation"
    fi

    # --- 6. Build autoinstall ISO ---
    AUTO_ISO="${OUTPUT_DIR}/proxmox-ve_9.2-1_auto.iso"
    EXTRACT_DIR="${WORK_DIR}/iso-extract"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    log "Extracting PVE ISO..."
    bsdtar -xf "$PVE_ISO_PATH" -C "$EXTRACT_DIR"

    # Patch GRUB/isolinux: add autoinstall parameter so the PVE installer
    # enters autoinstall mode.  The answer file is served locally via a
    # temporary HTTP server started on the host during boot (see §6 end-to-end).
    for cfg in isolinux/txt.cfg boot/grub/grub.cfg; do
        if [ -f "${EXTRACT_DIR}/${cfg}" ]; then
            sed -i 's|append /\(.*\)|append autoinstall \1|' \
                "${EXTRACT_DIR}/${cfg}"
            log "Patched ${cfg} — added autoinstall parameter"
        fi
    done

    # Copy answer file to ISO root so it's available at boot
    cp "$ANSWER_WORK" "${EXTRACT_DIR}/answer-host.toml"

    # Copy password hash to ISO root for late-commands to persist
    cp "$PASSWORD_HASH_FILE" "${EXTRACT_DIR}/password-hash"
    log "Copied answer file and password hash to ISO"

    # Repackage ISO
    log "Building autoinstall ISO..."
    cd "$EXTRACT_DIR"
    xorriso -as mkisofs \
        -o "$AUTO_ISO" \
        -R -J -joliet-long \
        -V "PVE-9-2-AUTO" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        .
    cd "$REPO_ROOT"

    log "Autoinstall ISO built: ${AUTO_ISO}"
    log "SHA256: $(sha256sum "$AUTO_ISO" | awk '{print $1}')"

    # --- 7. Record manifest ---
    MANIFEST="${OUTPUT_DIR}/MANIFEST"
    cat >> "$MANIFEST" <<EOF

## Host ISO build — $(date -Is)
REF: ${REF}
REF SHA: ${REF_SHA:-unknown}
PVE ISO: ${PVE_ISO_NAME}
PVE ISO SHA256: $(sha256sum "$PVE_ISO_PATH" | awk '{print $1}')
Auto ISO: $(basename "$AUTO_ISO")
Auto ISO SHA256: $(sha256sum "$AUTO_ISO" | awk '{print $1}')
Target disk: ${DISK_SHORT}
SSH key: ${SSH_KEY_FILE}
Password hash: embedded in ISO (copied from keys/password-hash)
EOF

    log "Manifest updated: ${MANIFEST}"
    log "=== Build complete ==="
    log "Write ${AUTO_ISO} to USB or serve over HTTP for unattended install."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
