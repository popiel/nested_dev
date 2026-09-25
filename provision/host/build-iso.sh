#!/usr/bin/env bash
# build-iso.sh — Build PVE 9.2 autoinstall ISO
# Downloads PVE ISO, injects answer file, produces proxmox-ve_9.2-1_auto.iso
# Uses proxmox-auto-install-assistant prepare-iso (native or Docker).
# REF: __GITHUB_REF__ (resolved at build time)
#
# Requirements: Linux x86_64, wget, proxmox-auto-install-assistant (native or Docker)
# Usage: ./build-iso.sh
set -euo pipefail

# --- Utilities (must be defined before first use) ---
log() { printf '[build-iso] %s\n' "$*"; }
die() { printf '[build-iso] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Pure functions (testable via source-guard) ---

download_iso() {
    local url="$1" dest="$2"
    if command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "$dest" "$url"
    else
        die "Missing: wget"
    fi
}

sed_escape() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//|/\\|}"
    val="${val//&/\\&}"
    val="${val//\$/\\\$}"
    echo "$val"
}

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
    local template="$1" disk_short="$2" ssh_key="$3" ref="$4" password_hash="$5" output="$6"
    local escaped_hash
    escaped_hash=$(sed_escape "$password_hash")
    sed \
        -e "s|__ROOT_SSH_KEY__|${ssh_key}|g" \
        -e "s|__AUTO_DETECT_DISK__|${disk_short}|g" \
        -e "s|__GITHUB_REF__|${ref}|g" \
        -e "s|__ROOT_PASSWORD_HASH__|${escaped_hash}|g" \
        "$template" > "$output"
}

run_prepare_iso() {
    local assistant="$1" pve_iso="$2" answer="$3" auto_iso="$4"
    log "Building autoinstall ISO via ${assistant}..."
    $assistant prepare-iso "$pve_iso" \
        --fetch-from iso \
        --answer-file "$answer" \
        --output "$auto_iso"
    log "Autoinstall ISO built: ${auto_iso}"
    log "SHA256: $(sha256sum "$auto_iso" | awk '{print $1}')"
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
    for cmd in wget sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
    done

    # Password hash (not committed — read at build time only)
    PASSWORD_HASH_FILE="${REPO_ROOT}/keys/password-hash"
    [ -f "$PASSWORD_HASH_FILE" ] || die "Missing: ${PASSWORD_HASH_FILE} (generate with mkpasswd)"
    PASSWORD_HASH=$(tr -d '\n' < "$PASSWORD_HASH_FILE")

    mkdir -p "$ISO_DIR" "$WORK_DIR"

    # --- 1. Download PVE ISO ---
    PVE_ISO_URL="https://na.cdn.proxmox.com/iso/proxmox-ve_9.2-1.iso"
    PVE_ISO_NAME="proxmox-ve_9.2-1.iso"
    PVE_ISO_PATH="${ISO_DIR}/${PVE_ISO_NAME}"
    PVE_ISO_SHA256="4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"

    if [ ! -s "$PVE_ISO_PATH" ]; then
        rm -f "$PVE_ISO_PATH"
        log "Downloading PVE 9.2 ISO..."
        if ! download_iso "$PVE_ISO_URL" "$PVE_ISO_PATH"; then
            rm -f "$PVE_ISO_PATH"
            die "Download failed — check network connectivity and URL: ${PVE_ISO_URL}"
        fi
        log "Downloaded: $(sha256sum "$PVE_ISO_PATH" | awk '{print $1}')"
    else
        log "PVE ISO already present: $PVE_ISO_PATH"
    fi

    # Always verify SHA256; re-download once on mismatch
    if ! echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - >/dev/null 2>&1; then
        log "SHA256 mismatch — re-downloading PVE ISO..."
        rm -f "$PVE_ISO_PATH"
        if ! download_iso "$PVE_ISO_URL" "$PVE_ISO_PATH"; then
            rm -f "$PVE_ISO_PATH"
            die "Re-download failed — check network connectivity"
        fi
        echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - \
            || die "ISO SHA256 mismatch after re-download"
        log "PVE ISO SHA256 verified (re-downloaded)"
    else
        log "PVE ISO SHA256 verified"
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
    if [ -n "$TARGET_DISK" ]; then
        DISK_SHORT=$(basename "$TARGET_DISK")
        log "Target disk: ${TARGET_DISK} (${DISK_SHORT})"
    else
        DISK_SHORT="sda"
        log "WARNING: No disk detected, defaulting to ${DISK_SHORT}"
    fi

    # --- 4. Generate answer file from template ---
    ANSWER_TEMPLATE="${SCRIPT_DIR}/answer-host.toml"
    ANSWER_WORK="${WORK_DIR}/answer-host.toml"

    [ -f "$ANSWER_TEMPLATE" ] || die "Answer template not found: ${ANSWER_TEMPLATE}"

    generate_answer_file "$ANSWER_TEMPLATE" "$DISK_SHORT" "$SSH_KEY" "$REF" \
        "$PASSWORD_HASH" "$ANSWER_WORK"
    log "Answer file generated: ${ANSWER_WORK}"

    # --- 5. Validate answer file ---
    ASSISTANT=""
    if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
        ASSISTANT="proxmox-auto-install-assistant"
    elif command -v docker >/dev/null 2>&1; then
        ASSISTANT="docker"
    else
        die "No proxmox-auto-install-assistant found.
  Install natively: apt install proxmox-auto-install-assistant xorriso
  Or install Docker and run: ./build-iso.sh (will pull container image)"
    fi

    if [ "$ASSISTANT" = "docker" ]; then
        log "Using Docker to run proxmox-auto-install-assistant..."
        # Build image from in-repo Dockerfile on first use
        ASSISTANT_IMAGE="nested-dev-proxmox-assistant"
        ASSISTANT_DF="${SCRIPT_DIR}/Dockerfile.autoinstall-assistant"
        if ! docker image inspect "$ASSISTANT_IMAGE" >/dev/null 2>&1; then
            [ -f "$ASSISTANT_DF" ] || die "Dockerfile not found: ${ASSISTANT_DF}"
            log "Building ${ASSISTANT_IMAGE} from Dockerfile..."
            docker build -t "$ASSISTANT_IMAGE" -f "$ASSISTANT_DF" "$SCRIPT_DIR" \
                || die "Failed to build ${ASSISTANT_IMAGE}"
        fi
    fi

    # Validate answer file
    if [ "$ASSISTANT" = "docker" ]; then
        log "Validating answer file schema..."
        docker run --rm \
            -v "${WORK_DIR}:/work" \
            "$ASSISTANT_IMAGE" \
            validate-answer "/work/$(basename "$ANSWER_WORK")" \
            || die "Answer file schema check failed — fix answer-host.toml"
    else
        log "Validating answer file schema..."
        $ASSISTANT validate-answer "$ANSWER_WORK" \
            || die "Answer file schema check failed — fix answer-host.toml"
    fi

    # --- 6. Build autoinstall ISO ---
    AUTO_ISO="${OUTPUT_DIR}/proxmox-ve_9.2-1_auto.iso"
    rm -f "$AUTO_ISO"

    if [ "$ASSISTANT" = "docker" ]; then
        docker run --rm \
            -v "${ISO_DIR}:/iso:ro" \
            -v "${WORK_DIR}:/work" \
            -v "${OUTPUT_DIR}:/output" \
            "$ASSISTANT_IMAGE" \
            prepare-iso "/iso/${PVE_ISO_NAME}" \
                --fetch-from iso \
                --answer-file "/work/$(basename "$ANSWER_WORK")" \
                --output "/output/$(basename "$AUTO_ISO")" \
            || die "prepare-iso failed"
    else
        run_prepare_iso "$ASSISTANT" "$PVE_ISO_PATH" "$ANSWER_WORK" "$AUTO_ISO"
    fi

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
Password hash: embedded in answer (root-password-hashed)
EOF

    log "Manifest updated: ${MANIFEST}"
    log "=== Build complete ==="
    log "Write ${AUTO_ISO} to USB or serve over HTTP for unattended install."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
