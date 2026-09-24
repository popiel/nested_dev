#!/usr/bin/env bash
# refresh-guests.sh — Re-fetch first-boot scripts into running guest VMs
# Run on host as root. Fetches from GitHub at the pinned REF, SCPs to each VM.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a /var/log/nested-dev-refresh.log; }
die() { printf '%s FATAL: %s\n' "$(date -Is)" "$*" | tee -a /var/log/nested-dev-refresh.log >&2; exit 1; }

# --- Source shared config ---
. /root/provision/personalization.sh 2>/dev/null || die "Cannot source personalization.sh"
. /root/provision/ubuntu-release.conf 2>/dev/null || true

GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
GITHUB_REF="${PERSONALIZATION_REF:-main}"
GITHUB_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}"

log "=== refresh-guests: fetching from ${GITHUB_REF} ==="

# --- Fetch scripts to temp dir ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPTS=(
    "desktop/desktop-firstboot.sh"
    "llm/llm-firstboot.sh"
    "dev/dev-firstboot.sh"
    "provision/personalization.sh"
)

for script in "${SCRIPTS[@]}"; do
    log "Fetching ${script}..."
    wget -q "${GITHUB_BASE}/${script}" -O "${TMPDIR}/$(basename "$script")" \
        || die "Failed to fetch ${script}"
done
chmod +x "${TMPDIR}"/*.sh

# --- SCP to running VMs ---
GUESTS=(
    "100:desktop:${PERSONALIZATION_USERNAME}"
    "101:llm:${PERSONALIZATION_USERNAME}"
    "102:dev-template:${PERSONALIZATION_USERNAME}"
)

for entry in "${GUESTS[@]}"; do
    IFS=: read -r vmid name user <<< "$entry"

    # Skip if VM not running
    if ! qm status "$vmid" 2>/dev/null | grep -q "running"; then
        log "VM ${vmid} (${name}) not running — skipping"
        continue
    fi

    # Determine which script to push
    case "$vmid" in
        100) GUEST_SCRIPT="desktop-firstboot.sh" ;;
        101) GUEST_SCRIPT="llm-firstboot.sh" ;;
        102) GUEST_SCRIPT="dev-firstboot.sh" ;;
    esac

    # SCP to VM via qm guest exec (uses guest agent)
    log "Pushing scripts to VM ${vmid} (${name})..."
    qm guest exec "$vmid" -- mkdir -p /opt/nested-dev 2>/dev/null || true

    for f in "${TMPDIR}/${GUEST_SCRIPT}" "${TMPDIR}/personalization.sh"; do
        fname=$(basename "$f")
        # Use qm guest file-write (guest agent) to push files
        CONTENT=$(base64 "$f")
        qm guest exec "$vmid" -- sh -c "echo '${CONTENT}' | base64 -d > /opt/nested-dev/${fname} && chmod +x /opt/nested-dev/${fname} && chown ${user}:${user} /opt/nested-dev/${fname}" 2>/dev/null \
            || log "WARNING: Could not push ${fname} to VM ${vmid}"
    done

    log "VM ${vmid} (${name}) refreshed"
done

log "=== refresh-guests complete ==="
