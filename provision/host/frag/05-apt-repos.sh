#!/usr/bin/env bash
# frag/05-apt-repos.sh — make apt usable before anything depends on it
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }
die() { log "FATAL: $*"; exit 1; }

# Overridable so the functions can be exercised without touching /etc; unset on a
# normal run, which is what keeps this a plain drop-in fragment.
: "${ENTERPRISE_LIST:=/etc/apt/sources.list.d/pve-enterprise.list}"
: "${NOSUB_LIST:=/etc/apt/sources.list.d/pve-no-subscription.list}"

# The suite is read out of the enterprise file rather than hardcoded, so this
# does not have to be edited when PVE moves to a new Debian release — and
# cannot be edited into the wrong one.
detect_suite() {
    local suite=""
    if [ -f "$ENTERPRISE_LIST" ]; then
        # A sources.list line is:  deb [<option> ...] <uri> <suite> [components]
        # so the suite is the field after the one holding the URI. Parsed by
        # position relative to the URI rather than by a fixed field number,
        # because `signed-by=` style options prepend fields and a hardcoded
        # index would then read an option as the suite.
        #
        # Deliberately not matching a /dists/ path: that is a PVE *apt* client
        # layout, and a PVE host's sources.list is `deb <url> <suite> <component>`
        # with no such path in it.
        suite=$(awk '
            /^[[:space:]]*deb[[:space:]]/ {
                for (i = 1; i < NF; i++) {
                    if ($i ~ /:\/\//) { print $(i + 1); exit }
                }
            }
        ' "$ENTERPRISE_LIST" | head -1)
    fi
    printf '%s\n' "${suite:-}"
}

enterprise_repos_enabled() {
    [ -f "$ENTERPRISE_LIST" ] || return 1
    grep -qE '^[[:space:]]*deb[[:space:]]' "$ENTERPRISE_LIST"
}

main() {
    log "=== APT repository setup ==="

    # A host without a PVE subscription gets 401 Unauthorized from
    # enterprise.proxmox.com. apt-get update then exits non-zero, and because
    # every fragment runs under `set -euo pipefail` the first one to call it
    # dies — which is how a repository problem presented as a memory/swap
    # failure and left the host with no guests at all: the run aborted at
    # frag/20 and frag/25 and frag/30 never executed.
    #
    # So this runs first, and it verifies apt actually works afterwards rather
    # than assuming the edit took.
    if ! enterprise_repos_enabled; then
        log "No enterprise repositories enabled — nothing to do"
        return 0
    fi

    local suite
    suite="$(detect_suite)"
    [ -n "$suite" ] || die "could not determine the Debian suite from ${ENTERPRISE_LIST}; refusing to guess"

    log "Enterprise repositories are enabled but return 401 without a subscription."
    log "  Disabling ${ENTERPRISE_LIST} and using the no-subscription repository for suite '${suite}'."

    # Comment out rather than delete, so the original is recoverable.
    sed -i 's/^\([[:space:]]*deb[[:space:]]\)/# \1/' "$ENTERPRISE_LIST"

    cat > "$NOSUB_LIST" <<EOF
# Added by frag/05-apt-repos.sh: this host has no PVE subscription, and the
# enterprise repository answers 401, which fails apt-get update and with it
# every fragment that installs a package.
deb http://download.proxmox.com/debian/pve ${suite} pve-no-subscription
EOF
    log "Wrote ${NOSUB_LIST}"

    apt-get update -qq \
        || die "apt-get update still fails after switching to the no-subscription repository; see the output above"

    log "apt-get update succeeds"
    log "=== APT repository setup complete ==="
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
