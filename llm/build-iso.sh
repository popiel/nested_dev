#!/usr/bin/env bash
# build-iso.sh — Build Ubuntu Server 26.04 autoinstall ISO for LLM VM
# Downloads Ubuntu Server ISO, injects user-data, produces autoinstall ISO.
# REF: host_os_v0.1
#
# Requirements: Linux x86_64, wget, xorriso, root or fakeroot
# Usage: sudo ./build-iso.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/output"
ISO_DIR="${OUTPUT_DIR}/iso"
WORK_DIR="${OUTPUT_DIR}/llm-build-work"
REF="host_os_v0.1"

# Source shared personalization (§05)
. "${REPO_ROOT}/provision/personalization.sh"

# Ubuntu Server 26.04 ISO — pin version and SHA256
UBUNTU_ISO_URL="https://releases.ubuntu.com/26.04/ubuntu-26.04-live-server-amd64.iso"
UBUNTU_ISO_NAME="ubuntu-26.04-live-server-amd64.iso"
UBUNTU_ISO_SHA256="CHANGE_ME_AFTER_DOWNLOAD"

log() { printf '[llm-iso] %s\n' "$*"; }
die() { printf '[llm-iso] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preflight ---
[ "$(id -u)" -eq 0 ] || die "Run as root (needed for xorriso)"
for cmd in wget xorriso; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd (apt-get install xorriso)"
done

mkdir -p "$ISO_DIR" "$WORK_DIR"

# --- 1. Download Ubuntu Server ISO ---
UBUNTU_ISO_PATH="${ISO_DIR}/${UBUNTU_ISO_NAME}"
if [ ! -f "$UBUNTU_ISO_PATH" ]; then
    log "Downloading Ubuntu Server 26.04 ISO..."
    wget -q --show-progress -O "$UBUNTU_ISO_PATH" "$UBUNTU_ISO_URL"
    log "Downloaded: $(sha256sum "$UBUNTU_ISO_PATH" | awk '{print $1}')"
else
    log "Ubuntu ISO already present: $UBUNTU_ISO_PATH"
fi

# Verify SHA256 (uncomment after updating UBUNTU_ISO_SHA256 above)
# echo "${UBUNTU_ISO_SHA256}  ${UBUNTU_ISO_PATH}" | sha256sum -c - || die "ISO SHA256 mismatch"

# --- 2. Extract ISO ---
EXTRACT_DIR="${WORK_DIR}/iso-extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
log "Extracting ISO..."
bsdtar -xf "$UBUNTU_ISO_PATH" -C "$EXTRACT_DIR"

# --- 3. Patch GRUB/isolinux to add autoinstall ---
for cfg in isolinux/txt.cfg boot/grub/grub.cfg; do
    if [ -f "${EXTRACT_DIR}/${cfg}" ]; then
        sed -i 's|append \(.*\)|append autoinstall ds=nocloud\;s=/cdrom/ \1|' \
            "${EXTRACT_DIR}/${cfg}"
        log "Patched ${cfg}"
    fi
done

# --- 4. Copy user-data to ISO root as cidata ---
mkdir -p "${EXTRACT_DIR}/cidata"
# Substitute personalization placeholders (§05)
sed -e "s/__PERSONALIZATION_USERNAME__/${PERSONALIZATION_USERNAME}/g" \
    -e "s/__PERSONALIZATION_FULLNAME__/${PERSONALIZATION_FULLNAME}/g" \
    -e "s/__PERSONALIZATION_EMAIL__/${PERSONALIZATION_EMAIL}/g" \
    "${SCRIPT_DIR}/user-data/user-data" > "${EXTRACT_DIR}/cidata/user-data"
cp "${SCRIPT_DIR}/user-data/meta-data" "${EXTRACT_DIR}/cidata/meta-data"
log "Copied user-data to cidata/ (personalization substituted)"

# --- 5. Copy first-boot script and personalization to ISO root ---
# The first-boot script is fetched at <REF> inside the VM, but we also
# embed it on the ISO as a fallback for air-gapped installs.
cp "${SCRIPT_DIR}/llm-firstboot.sh" "${EXTRACT_DIR}/llm-firstboot.sh"
chmod +x "${EXTRACT_DIR}/llm-firstboot.sh"
cp "${REPO_ROOT}/provision/personalization.sh" "${EXTRACT_DIR}/personalization.sh"
chmod +x "${EXTRACT_DIR}/personalization.sh"
log "Embedded llm-firstboot.sh and personalization.sh on ISO"

# --- 6. Repackage ISO ---
LLM_AUTO_ISO="${OUTPUT_DIR}/ubuntu-26.04-server-amd64_auto.iso"
log "Building autoinstall ISO..."
cd "$EXTRACT_DIR"
xorriso -as mkisofs \
    -o "$LLM_AUTO_ISO" \
    -R -J -joliet-long \
    -V "UBUNTU-26-04-SERVER-AUTO" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    .
cd "$REPO_ROOT"

log "Autoinstall ISO built: ${LLM_AUTO_ISO}"
log "SHA256: $(sha256sum "$LLM_AUTO_ISO" | awk '{print $1}')"

# --- 7. Record manifest ---
MANIFEST="${OUTPUT_DIR}/MANIFEST"
cat >> "$MANIFEST" <<EOF

## LLM ISO build — $(date -Is)
REF: ${REF}
Ubuntu ISO: ${UBUNTU_ISO_NAME}
Ubuntu ISO SHA256: $(sha256sum "$UBUNTU_ISO_PATH" | awk '{print $1}')
Auto ISO: $(basename "$LLM_AUTO_ISO")
Auto ISO SHA256: $(sha256sum "$LLM_AUTO_ISO" | awk '{print $1}')
EOF

log "Manifest updated: ${MANIFEST}"
log "=== Build complete ==="
log "Write ${LLM_AUTO_ISO} to USB or serve over HTTP for unattended install."
log "The VM will fetch llm-firstboot.sh from GitHub at REF ${REF} on first boot."
