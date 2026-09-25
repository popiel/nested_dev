#!/bin/sh
# provision/host/first-boot.sh — TEMPLATE, rendered at build time by build-iso.sh
#
# Embedded into the installer ISO via `prepare-iso --on-first-boot` and run
# once, after installation, by the PVE `proxmox-first-boot` package. It is the
# schema-supported replacement for the `[late-commands]` section that older
# versions of this answer file carried (PVE's autoinstall schema has no such
# section — only global, network, disk-setup, post-installation-webhook and
# first-boot).
#
# Responsibilities, in order:
#   1. Persist the root password hash to /root/.password-hash for frag/30,
#      which injects it into the guest NoCloud seeds.
#   2. Fetch the provision/ tree at the pinned REF.
#   3. Install the pve-firstboot.service oneshot unit.
#
# SECURITY: this rendered file contains the root password hash in plaintext and
# is therefore as sensitive as keys/password-hash itself. It is written to
# output/build-work/ (gitignored) and embedded in the ISO. It is never pushed to
# GitHub — the hash reaches the booted host through the installer media only.
#
# REF: __GITHUB_REF__ (baked at build time)

set -eu

REF="__GITHUB_REF__"
REPO="popiel/nested_dev"
PROVISION_DIR="/root/provision"
HASH_FILE="/root/.password-hash"
UNIT="/etc/systemd/system/pve-firstboot.service"
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
LOG="/var/log/pve-firstboot-bootstrap.log"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# --- 1. Persist the root password hash -------------------------------
# The hash is substituted here at build time. It is the same value the answer
# file handed to the installer as `root-password-hashed`.
log "persisting root password hash"
umask 077
printf '%s' '__ROOT_PASSWORD_HASH__' > "$HASH_FILE"
chmod 600 "$HASH_FILE"

# --- 2. Fetch the provision/ tree at the pinned REF -------------------
log "fetching provisioner tree at ${REF}"
mkdir -p "$PROVISION_DIR"
TMP="/root/.nested_dev.tar.gz"
if ! wget -qO "$TMP" "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"; then
    rm -f "$TMP"
    die "failed to fetch provisioner tree for ${REPO}@${REF}"
fi
tar -xzf "$TMP" -C /root
rm -f "$TMP"
[ -d "/root/nested_dev-${REF}/provision" ] || die "archive did not contain provision/"
rm -rf "${PROVISION_DIR:?}.old"
[ -d "$PROVISION_DIR" ] && mv "$PROVISION_DIR" "${PROVISION_DIR}.old"
mv "/root/nested_dev-${REF}/provision" "$PROVISION_DIR"
rm -rf "/root/nested_dev-${REF}"
chmod +x "${PROVISION_DIR}/host/provision-host.sh"
chmod +x "${PROVISION_DIR}/host"/frag/*.sh 2>/dev/null || true

# --- 3. Install the pve-firstboot unit --------------------------------
log "installing pve-firstboot.service"
cat > "$UNIT" <<UNIT
[Unit]
Description=PVE first boot provisioning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${PROVISION_DIR}/host/provision-host.sh

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$WANTS_DIR"
ln -sf "$UNIT" "${WANTS_DIR}/pve-firstboot.service"
systemctl daemon-reload
systemctl enable pve-firstboot.service >/dev/null 2>&1 || true

# --- Run the provisioner now ------------------------------------------
# This hook executes during the first boot, so merely enabling the unit would
# defer provisioning to the *second* boot. Install the unit (it stays available
# for manual re-runs and for `systemctl status` diagnostics) but drive the
# provisioner directly. Fragments are idempotent, so a later re-run is safe.
log "running provisioner"
if ! /bin/sh "${PROVISION_DIR}/host/provision-host.sh"; then
    die "provisioner failed — see /var/log/pve-firstboot.log"
fi

log "=== first-boot bootstrap complete ==="
