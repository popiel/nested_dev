#!/usr/bin/env bash
# provision-host.sh — first-boot entry point for PVE 9.2 host
# Runs from systemd oneshot; sources fragments in order; self-disables on success.
# REF: __GITHUB_REF__ (baked at build time)
set -euo pipefail

# Filesystem root for everything this provisioner writes. Empty on a real host,
# so all paths below are the production paths. The end-to-end test points it at
# a scratch tree and asserts the resulting state, which is what makes the whole
# run — not any one fragment's source text — the thing under test.
ROOT="${PVE_ROOT:-}"

LOG="${ROOT}/var/log/pve-firstboot.log"
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
#
# The lock is held by re-executing under flock(1), never as an fd kept open
# for the run. An fd lock (exec 9>...; flock 9) is inherited by every child —
# including daemons that never exit. frag/28 starts dhclient daemons mid-run,
# and each one carried a copy of the lock forever: every later run hung on
# acquisition with no provisioner running anywhere, fuser showing only dhclient
# holding the file. With --close, flock holds the lock in the waiting parent
# while the script, its fragments, and anything they daemonize run without the
# fd, so a daemon can never inherit it again.
LOCK_FILE="${ROOT}/run/lock/pve-firstboot.lock"
COMPLETE_MARKER="${ROOT}/var/lib/pve-firstboot/complete"
REBOOT_MARKER="${ROOT}/var/lib/pve-firstboot/rebooted"

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$COMPLETE_MARKER")"

if [ "${PVE_FIRSTBOOT_LOCKED:-}" != "1" ]; then
    export PVE_FIRSTBOOT_LOCKED=1
    log "=== pve-firstboot starting ==="
    log "waiting for the provisioning lock (${LOCK_FILE})"
    # Explicit bash: this script needs it (pipefail, [[ ]] below), and $0
    # re-executed through the shebang would depend on the installer's exec bit.
    # No arguments are ever passed; the branch keeps "$@" correct under set -u
    # on old bash, where an empty "$@" aborts.
    if [ "$#" -gt 0 ]; then
        exec flock --close "$LOCK_FILE" bash "$0" "$@"
    else
        exec flock --close "$LOCK_FILE" bash "$0"
    fi
fi
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

    # --- reboot to activate the vfio-pci binding, exactly once ---
    # frag/10 writes the GRUB cmdline, modprobe config and initramfs that bind
    # the passthrough devices — but all three take effect at boot, and nothing
    # unbinds the host driver live. A guest started before that reboot fails
    # attaching hardware the host kernel still holds. So the run reboots after
    # the network is up (frag/28, the last thing needed before guests) and the
    # still-enabled unit resumes the run after boot; every fragment is
    # idempotent, so the post-boot pass is fast no-ops up to frag/30.
    #
    # Suppressed under PVE_ROOT: the test harness must observe the marker and
    # the continuation, not reboot the machine running the tests.
    if [[ "$frag" == */28-network.sh ]] && [ ! -f "$REBOOT_MARKER" ]; then
        date -Is > "$REBOOT_MARKER"
        if [ -z "${PVE_ROOT:-}" ]; then
            log "rebooting once to activate the vfio-pci binding; provisioning resumes after boot"
            systemctl reboot
            sleep 60
            log "ERROR: reboot was requested but the machine is still up"
            exit 1
        else
            log "(reboot suppressed: PVE_ROOT is set)"
        fi
    fi
done

date -Is > "$COMPLETE_MARKER"
log "=== pve-firstboot complete — disabling unit ==="
systemctl disable --now pve-firstboot
log "=== done ==="
