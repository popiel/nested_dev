#!/usr/bin/env bash
# provision-host.sh — first-boot entry point for PVE 9.2 host
# Runs from systemd oneshot; sources fragments in order; self-disables on success.
# REF: host_os_v0.1
set -euo pipefail

LOG="/var/log/pve-firstboot.log"
FRAG_DIR="$(dirname "$0")/frag"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "=== pve-firstboot starting ==="

for frag in "$FRAG_DIR"/*.sh; do
    [ -f "$frag" ] || continue
    log "--- running $(basename "$frag") ---"
    if ! bash "$frag" >>"$LOG" 2>&1; then
        log "ERROR: $(basename "$frag") failed — see $LOG"
        exit 1
    fi
    log "--- $(basename "$frag") OK ---"
done

log "=== pve-firstboot complete — disabling unit ==="
systemctl disable --now pve-firstboot
log "=== done ==="
