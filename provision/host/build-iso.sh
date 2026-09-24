#!/usr/bin/env bash
# build-iso.sh — Build PVE 9.2 autoinstall ISO
# Downloads PVE ISO, injects answer file, produces proxmox-ve_9.2-1_auto.iso
# REF: __GITHUB_REF__ (resolved at build time)
#
# Requirements: Linux x86_64, wget, xorriso (or genisoimage), root or fakeroot
# Usage: sudo ./build-iso.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output"
ISO_DIR="${OUTPUT_DIR}/iso"
WORK_DIR="${OUTPUT_DIR}/build-work"

# Source shared personalization (§05)
. "${REPO_ROOT}/provision/personalization.sh"
REF="${PERSONALIZATION_REF}"

# Resolve REF to commit SHA (works for branches, tags, and literal SHAs)
resolve_ref_to_sha() {
    local repo="$1" ref="$2"
    # Already a 40-char hex SHA? Return as-is.
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$ref"
        return
    fi
    local sha=""
    # Try branches first, then tags
    sha=$(git ls-remote "https://github.com/${repo}.git" "refs/heads/${ref}" 2>/dev/null | awk '{print $1}')
    if [ -z "$sha" ]; then
        sha=$(git ls-remote "https://github.com/${repo}.git" "refs/tags/${ref}" 2>/dev/null | awk '{print $1}')
    fi
    echo "$sha"
}

log "Resolving REF '${REF}' to SHA..."
REF_SHA=$(resolve_ref_to_sha "${PERSONALIZATION_REPO}" "${REF}")
if [ -n "$REF_SHA" ]; then
    log "REF resolved: ${REF} -> ${REF_SHA:0:12}"
else
    log "WARNING: Could not resolve REF '${REF}' — proceeding with branch name only"
fi

# PVE 9.2 ISO — pin version and SHA256
PVE_ISO_URL="https://download.proxmox.com/iso/proxmox-ve_9.2-1.iso"
PVE_ISO_NAME="proxmox-ve_9.2-1.iso"
PVE_ISO_SHA256="CHANGE_ME_AFTER_DOWNLOAD"  # Update after first verified download

log() { printf '[build-iso] %s\n' "$*"; }
die() { printf '[build-iso] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preflight ---
[ "$(id -u)" -eq 0 ] || die "Run as root (needed for xorriso/isohybrid)"
for cmd in wget xorriso; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd (apt-get install xorriso)"
done

# Password hash (not committed — read at build time only)
PASSWORD_HASH_FILE="${REPO_ROOT}/keys/password-hash"
[ -f "$PASSWORD_HASH_FILE" ] || die "Missing: ${PASSWORD_HASH_FILE} (generate with mkpasswd)"

mkdir -p "$ISO_DIR" "$WORK_DIR"

# --- 1. Download PVE ISO ---
PVE_ISO_PATH="${ISO_DIR}/${PVE_ISO_NAME}"
if [ ! -f "$PVE_ISO_PATH" ]; then
    log "Downloading PVE 9.2 ISO..."
    wget -q --show-progress -O "$PVE_ISO_PATH" "$PVE_ISO_URL"
    log "Downloaded: $(sha256sum "$PVE_ISO_PATH" | awk '{print $1}')"
else
    log "PVE ISO already present: $PVE_ISO_PATH"
fi

# Verify SHA256 (uncomment after updating PVE_ISO_SHA256 above)
# echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - || die "ISO SHA256 mismatch"

# --- 2. Read SSH public key ---
SSH_KEY_FILE="${REPO_ROOT}/keys/host_os_ed25519.pub"
if [ ! -f "$SSH_KEY_FILE" ]; then
    die "SSH public key not found: ${SSH_KEY_FILE}"
fi
SSH_KEY=$(cat "$SSH_KEY_FILE" | tr -d '\n')
log "SSH key loaded from ${SSH_KEY_FILE}"

# --- 3. Auto-detect target disk ---
# Prefer NVMe, then SSD, then first available
TARGET_DISK=""
for disk in /dev/nvme?n?; do
    [ -b "$disk" ] && TARGET_DISK="$disk" && break
done
if [ -z "$TARGET_DISK" ]; then
    for disk in /dev/sd?; do
        # Check if SSD (rotational = 0)
        if [ -f "/sys/block/$(basename "$disk")/queue/rotational" ]; then
            ROTA=$(cat "/sys/block/$(basename "$disk")/queue/rotational")
            if [ "$ROTA" -eq 0 ]; then
                TARGET_DISK="$disk"
                break
            fi
        fi
    done
fi
if [ -z "$TARGET_DISK" ]; then
    # Fallback: first /dev/sd?
    for disk in /dev/sd?; do
        [ -b "$disk" ] && TARGET_DISK="$disk" && break
    done
fi
[ -n "$TARGET_DISK" ] || die "No disk detected for target"

# Convert /dev/sdX to sdX for answer file, or /dev/nvme0n1 to nvme0n1
DISK_SHORT=$(basename "$TARGET_DISK")
log "Target disk: ${TARGET_DISK} (${DISK_SHORT})"

# --- 4. Generate answer file from template ---
ANSWER_TEMPLATE="${SCRIPT_DIR}/answer-host.toml"
ANSWER_WORK="${WORK_DIR}/answer-host.toml"

if [ ! -f "$ANSWER_TEMPLATE" ]; then
    die "Answer template not found: ${ANSWER_TEMPLATE}"
fi

# Substitute placeholders
sed \
    -e "s|__ROOT_SSH_KEY__|${SSH_KEY}|g" \
    -e "s|__AUTO_DETECT_DISK__|${DISK_SHORT}|g" \
    -e "s|__GITHUB_REF__|${REF}|g" \
    "$ANSWER_TEMPLATE" > "$ANSWER_WORK"

log "Answer file generated: ${ANSWER_WORK}"

# --- 4b. Verify answer file with PVE tool (optional, schema check only) ---
if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
    log "Verifying answer file schema..."
    proxmox-auto-install-assistant verify "$ANSWER_WORK" || log "WARNING: Answer file schema check failed"
fi

# --- 5. Build autoinstall ISO (manual extraction — includes password hash) ---
AUTO_ISO="${OUTPUT_DIR}/proxmox-ve_9.2-1_auto.iso"
EXTRACT_DIR="${WORK_DIR}/iso-extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

log "Extracting PVE ISO..."
bsdtar -xf "$PVE_ISO_PATH" -C "$EXTRACT_DIR"

# Patch GRUB/isolinux to add autoinstall parameter
for cfg in isolinux/txt.cfg boot/grub/grub.cfg; do
    if [ -f "${EXTRACT_DIR}/${cfg}" ]; then
        sed -i 's|append /boot/\(.*\)|append autoinstall ds=nocloud;s=http://localhost/ \1|' \
            "${EXTRACT_DIR}/${cfg}"
        log "Patched ${cfg}"
    fi
done

# Copy answer file + password hash to ISO root as cidata
mkdir -p "${EXTRACT_DIR}/cidata"
cp "$ANSWER_WORK" "${EXTRACT_DIR}/cidata/user-data"
echo "#cloud-config" > "${EXTRACT_DIR}/cidata/meta-data"
cp "$PASSWORD_HASH_FILE" "${EXTRACT_DIR}/password-hash"
log "Copied answer file, meta-data, and password hash to ISO"

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
