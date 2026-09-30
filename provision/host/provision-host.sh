#!/usr/bin/env bash
# provision-host.sh — first-boot entry point for PVE 9.2 host
# Runs from systemd oneshot; sources fragments in order; self-disables on success.
# REF: __GITHUB_REF__ (baked at build time)
set -euo pipefail

LOG="/var/log/pve-firstboot.log"
FRAG_DIR="$(dirname "$0")/frag"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

# --- single-run lock ------------------------------------------------------
# This script is reached two ways on the same boot: the systemd oneshot that
# multi-user.target starts, and the direct call first-boot.sh makes so that
# provisioning happens on the first boot rather than the second. Both used to
# run at once.
#
# That is not cosmetic. frag/10 rebuilds the initramfs to bind the passthrough
# devices, and two update-initramfs runs against the same tree interleave their
# temporary files — the observed result was one run failing with
# `mv: cannot stat /boot/initrd.img-7.0.2-6-pve.new` while the other succeeded.
# Which fragment each run was on at the time was luck, so a real failure and a
# spurious one were indistinguishable in the log.
#
# The lock lives here rather than in first-boot.sh so it covers every entry
# path: the unit, the direct call, and a manual re-run.
#
# The second arrival *waits* rather than exiting. Exiting 0 would let
# first-boot.sh declare the bootstrap complete while provisioning was still in
# progress; exiting non-zero would fail the run that did nothing wrong.
LOCK_FILE="/run/lock/pve-firstboot.lock"
COMPLETE_MARKER="/var/lib/pve-firstboot/complete"

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$COMPLETE_MARKER")"

exec 9>"$LOCK_FILE"
log "=== pve-firstboot starting ==="
log "waiting for the provisioning lock (${LOCK_FILE})"
flock 9
log "acquired the provisioning lock"

if [ -f "$COMPLETE_MARKER" ]; then
    log "another run already completed provisioning — nothing to do"
    exit 0
fi

for frag in "$FRAG_DIR"/*.sh; do
    [ -f "$frag" ] || continue
    log "--- running $(basename "$frag") ---"
    if ! bash "$frag" >>"$LOG" 2>&1; then
        log "ERROR: $(basename "$frag") failed — see $LOG"
        # No marker is written, so a retry after the cause is fixed proceeds
        # normally instead of being short-circuited as "already done".
        exit 1
    fi
    log "--- $(basename "$frag") OK ---"
done

date -Is > "$COMPLETE_MARKER"
log "=== pve-firstboot complete — disabling unit ==="
systemctl disable --now pve-firstboot
log "=== done ==="
