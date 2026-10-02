#!/usr/bin/env bash
# provision/host/refresh-provisioner.sh — update the provisioning tree on an
# installed host and re-run it. Version 1.
#
# Routine operation, not surgery. Pulling new commits (seed fixes, firewall
# changes) onto a host that already provisioned once, so the next guest build
# uses them. A hand-rolled fetch-and-swap gets three things wrong that this
# script does right: it runs the on-host copy without refetching (stale tree),
# it re-runs without removing the completion marker (silent no-op), and it
# swaps in an archive it never verified (a bad fetch leaves no working tree).
#
# Order is load-bearing throughout: fetch, verify, swap, unlock, run. Nothing
# is replaced until the replacement is proven good, and the completed run is
# never unlocked until the new tree is in place — so any failure leaves the
# host running the previous working tree, still marked complete.
#
# Usage (on the host, as root):
#   /bin/sh /root/refresh-provisioner.sh
#
# Bootstrap (first use only — this script is not in the host's tree yet, and it
# lives outside the swapped tree so later fetches never move it):
#   wget -q https://raw.githubusercontent.com/popiel/nested_dev/main/provision/host/refresh-provisioner.sh \
#       -O /root/refresh-provisioner.sh
# Re-download it when the repo copy changes; the version above is announced in
# every run's log, so drift is visible rather than silent.
#
# One operator at a time: concurrent runs would race the tree swap. The
# provisioner itself serializes its own runs behind a lock, but the swap here
# is outside that lock.
#
# Optional environment:
#   REFRESH_REPO / REFRESH_REF — repo and branch to fetch. Default: the values
#     in the live tree's personalization.sh, falling back to popiel/nested_dev
#     and main when the live tree has none yet.
#   REFRESH_TARBALL_SRC — path to a tarball to use instead of fetching. The
#     test seam: it keeps the suite hermetic (no network) while exercising the
#     same verify-swap-run path byte for byte.
#   PVE_ROOT — scratch redirect for tests, same contract as provision-host.sh.
#
# Exit status is the provisioner's. Zero means the tree is refreshed AND the
# run completed (the completion marker is re-created and checked). Anything
# else names the failed step and the log holding the details.
set -euo pipefail

REFRESH_VERSION="1"

ROOT="${PVE_ROOT:-}"
PROVISION_DIR="${ROOT}/root/provision"
COMPLETE_MARKER="${ROOT}/var/lib/pve-firstboot/complete"
LOG="${ROOT}/var/log/pve-firstboot.log"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$(dirname "$LOG")"
log "=== refresh-provisioner v${REFRESH_VERSION} starting ==="

# --- preconditions: fail before touching anything ---
if [ -z "${PVE_ROOT:-}" ]; then
    [ "$(id -u)" -eq 0 ] || die "must run as root (outside tests)"
    command -v qm >/dev/null 2>&1 || die "no 'qm' on PATH — not a PVE host?"
    command -v wget >/dev/null 2>&1 || die "no 'wget' — cannot fetch the tree"
    command -v tar >/dev/null 2>&1 || die "no 'tar' — cannot unpack the tree"
fi
[ -d "$PROVISION_DIR" ] || die "no live tree at $PROVISION_DIR — nothing to refresh"

# Repo and branch: explicit env wins, then the live tree's own record of where
# it came from, then the project defaults. Grepped, not sourced:
# personalization.sh is shell code, and executing it for two variables would
# run whatever else it does.
REPO="${REFRESH_REPO:-}"
REF="${REFRESH_REF:-}"
if [ -z "$REPO" ] && [ -f "${PROVISION_DIR}/personalization.sh" ]; then
    REPO="$(grep -E '^PERSONALIZATION_REPO=' "${PROVISION_DIR}/personalization.sh" \
        | cut -d= -f2- | tr -d '"' || true)"
fi
if [ -z "$REF" ] && [ -f "${PROVISION_DIR}/personalization.sh" ]; then
    REF="$(grep -E '^PERSONALIZATION_REF=' "${PROVISION_DIR}/personalization.sh" \
        | cut -d= -f2- | tr -d '"' || true)"
fi
REPO="${REPO:-popiel/nested_dev}"
REF="${REF:-main}"
log "fetching ${REPO}@${REF}"

# --- fetch into a staging area, never into the live tree ---
STAGE="$(mktemp -d "${ROOT}/root/.refresh-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
TARBALL="${STAGE}/tree.tar.gz"
if [ -n "${REFRESH_TARBALL_SRC:-}" ]; then
    [ -f "$REFRESH_TARBALL_SRC" ] \
        || die "REFRESH_TARBALL_SRC=${REFRESH_TARBALL_SRC} is not a file"
    cp "$REFRESH_TARBALL_SRC" "$TARBALL"
    log "using staged tarball ${REFRESH_TARBALL_SRC}"
elif ! wget -qO "$TARBALL" "https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}"; then
    die "failed to fetch ${REPO}@${REF} — live tree untouched, marker still in place"
fi
[ -s "$TARBALL" ] || die "fetched an empty tarball — live tree untouched"

# --- verify the replacement before anything is replaced ---
# The top-level directory is derived from the archive itself, not guessed from
# the branch name: a wrong guess would pass extraction and then fail the swap
# halfway, which is exactly the half-replaced tree this ordering exists to
# prevent. Listed to a file first: piping tar straight into head closes the
# pipe early, and under pipefail tar's resulting SIGPIPE would fail even a
# good archive.
tar -tzf "$TARBALL" > "${STAGE}/contents.txt"
REF_DIR="$(head -n 1 "${STAGE}/contents.txt" | cut -d/ -f1)"
[ -n "$REF_DIR" ] || die "could not list the tarball — live tree untouched"
tar -xzf "$TARBALL" -C "$STAGE"
NEW_TREE="${STAGE}/${REF_DIR}/provision"
[ -x "${NEW_TREE}/host/provision-host.sh" ] \
    || [ -f "${NEW_TREE}/host/provision-host.sh" ] \
    || die "archive has no provision/host/provision-host.sh — live tree untouched"
[ -f "${STAGE}/${REF_DIR}/keys/host_os_ed25519.pub" ] \
    || die "archive has no keys/host_os_ed25519.pub — frag/30 would abort after everything else succeeded; live tree untouched"
log "verified: ${REF_DIR}/provision/host/provision-host.sh and keys pubkey present"

# --- swap: the old tree stays reachable as .old until the run completes ---
rm -rf "${PROVISION_DIR:?}.old"
mv "$PROVISION_DIR" "${PROVISION_DIR}.old"
mv "$NEW_TREE" "$PROVISION_DIR"
# keys/ is not part of the provision tree, so preserve the pubkey out of the
# archive into the tree just put in place. After the swap, not before: staging
# it into the old directory and then moving that directory to .old loses it.
mkdir -p "${PROVISION_DIR}/keys"
cp "${STAGE}/${REF_DIR}/keys/host_os_ed25519.pub" "${PROVISION_DIR}/keys/host_os_ed25519.pub"
chmod 644 "${PROVISION_DIR}/keys/host_os_ed25519.pub"
chmod +x "${PROVISION_DIR}/host/provision-host.sh"
chmod +x "${PROVISION_DIR}"/host/frag/*.sh 2>/dev/null || true
log "tree swapped: previous tree at ${PROVISION_DIR}.old"

# --- unlock, then run: the marker comes out only now ---
# Removing it earlier would let a failed fetch or a rejected archive unlock a
# re-run of the old tree; removing it later is impossible, because the
# provisioner no-ops while it exists.
rm -f "$COMPLETE_MARKER"
log "completion marker removed — running the provisioner"
if ! /bin/sh "${PROVISION_DIR}/host/provision-host.sh"; then
    die "provisioner failed — previous tree at ${PROVISION_DIR}.old, no completion marker written so a retry proceeds; see $LOG"
fi

# --- post-checks: the run claims success only if the marker is back ---
[ -f "$COMPLETE_MARKER" ] \
    || die "provisioner exited 0 but wrote no completion marker — refusing to report success"
log "completion marker re-created"
log "=== refresh-provisioner v${REFRESH_VERSION} complete: ${REPO}@${REF} live ==="
