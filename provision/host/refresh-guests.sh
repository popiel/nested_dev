#!/usr/bin/env bash
# refresh-guests.sh — Re-fetch first-boot scripts into running guest VMs
# Run on host as root. Defaults to the recorded per-guest SHA in
# /etc/nested-dev/ref-sha.d/<vmid> (falling back to /etc/nested-dev/ref-sha,
# then the live tree's PERSONALIZATION_REF); override with:
#   refresh-guests.sh [--ref <branch|tag|sha>] [--guest <vmid>=<ref>]...
# or REFRESH_REF / REFRESH_GUEST_<vmid> env vars.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a /var/log/nested-dev-refresh.log; }
die() { printf '%s FATAL: %s\n' "$(date -Is)" "$*" | tee -a /var/log/nested-dev-refresh.log >&2; exit 1; }

# --- Source shared config ---
. /root/provision/personalization.sh 2>/dev/null || die "Cannot source personalization.sh"
. /root/provision/ubuntu-release.conf 2>/dev/null || true

GITHUB_REPO="${PERSONALIZATION_REPO:-popiel/nested_dev}"
DEFAULT_REF="${PERSONALIZATION_REF:-main}"
# Recorded SHAs win over the live tree: a rebuild defaults to what built the
# guest unless the operator passes a new ref explicitly.
if [ -s /etc/nested-dev/ref-sha ]; then
    DEFAULT_REF="$(tr -d '\n' < /etc/nested-dev/ref-sha)"
fi
[ -n "${REFRESH_REF:-}" ] && DEFAULT_REF="$REFRESH_REF"

# CLI overrides: --ref <ref> (all guests), --guest <vmid>=<ref> (one guest).
declare -A GUEST_REF_OVERRIDE=()
CLI_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) CLI_REF="${2:-}"; shift 2 ;;
        --guest) _g="${2:-}"; _id="${_g%%=*}"; _rf="${_g#*=}"; GUEST_REF_OVERRIDE["$_id"]="$_rf"; shift 2 ;;
        -h|--help) echo "Usage: refresh-guests.sh [--ref <branch|tag|sha>] [--guest <vmid>=<ref>]..."; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$CLI_REF" ] && DEFAULT_REF="$CLI_REF"
GITHUB_REF="$DEFAULT_REF"

guest_ref() {
    local vmid="$1"
    local envvar="REFRESH_GUEST_${vmid}"
    [ -n "${GUEST_REF_OVERRIDE[$vmid]:-}" ] && { printf '%s\n' "${GUEST_REF_OVERRIDE[$vmid]}"; return; }
    [ -n "${!envvar:-}" ] && { printf '%s\n' "${!envvar}"; return; }
    [ -s "/etc/nested-dev/ref-sha.d/${vmid}" ] && { tr -d '\n' < "/etc/nested-dev/ref-sha.d/${vmid}"; return; }
    printf '%s\n' "$GITHUB_REF"
}

log "=== refresh-guests: default ${GITHUB_REF} (per-guest overrides from /etc/nested-dev/ref-sha.d/) ==="

# --- Fetch + push per guest (each guest may pin a different SHA) ---
# TMPDIR holds one subdirectory per vmid so guests at different SHAs never
# share files.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

fetch_for_guest() {
    local vmid="$1" ref="$2" destdir="$3" script
    local base="https://raw.githubusercontent.com/${GITHUB_REPO}/${ref}"
    mkdir -p "$destdir"
    for script in desktop/desktop-firstboot.sh desktop/devctl llm/llm-firstboot.sh dev/dev-firstboot.sh provision/personalization.sh; do
        log "VM ${vmid}: fetching ${script}@${ref}..."
        wget -q "${base}/${script}" -O "${destdir}/$(basename "$script")" \
            || die "VM ${vmid}: failed to fetch ${script}@${ref}"
    done
    chmod +x "${destdir}"/*
}

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
    REF="$(guest_ref "$vmid")"
    GUEST_TMP="${TMPDIR}/${vmid}"
    fetch_for_guest "$vmid" "$REF" "$GUEST_TMP"

    # Files to push: the first-boot script, personalization, and (desktop
    # only) the devctl source firstboot installs from. The copy into
    # ~/.local/bin stays manual — firstboot is one-shot by design.
    push_files=("${GUEST_TMP}/${GUEST_SCRIPT}" "${GUEST_TMP}/personalization.sh")
    [ "$vmid" = "100" ] && push_files+=("${GUEST_TMP}/devctl")

    # SCP to VM via qm guest exec (uses guest agent)
    log "Pushing scripts to VM ${vmid} (${name})..."
    qm guest exec "$vmid" -- mkdir -p /opt/nested-dev 2>/dev/null || true

    for f in "${push_files[@]}"; do
        fname=$(basename "$f")
        # Use qm guest file-write (guest agent) to push files
        CONTENT=$(base64 "$f")
        qm guest exec "$vmid" -- sh -c "echo '${CONTENT}' | base64 -d > /opt/nested-dev/${fname} && chmod +x /opt/nested-dev/${fname} && chown ${user}:${user} /opt/nested-dev/${fname}" 2>/dev/null \
            || log "WARNING: Could not push ${fname} to VM ${vmid}"
    done

    log "VM ${vmid} (${name}) refreshed from ${REF}"
done

log "=== refresh-guests complete ==="
