#!/usr/bin/env bash
# frag/05-apt-repos.sh — make apt usable before anything depends on it
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }
die() { log "FATAL: $*"; exit 1; }

# Overridable so the functions can be exercised without touching /etc; unset on a
# normal run, which is what keeps this a plain drop-in fragment.
ROOT="${PVE_ROOT:-}"
: "${APT_SOURCES_DIR:=${ROOT}/etc/apt/sources.list.d}"
: "${APT_SOURCES_LIST:=${ROOT}/etc/apt/sources.list}"
: "${NOSUB_LIST:=${ROOT}/etc/apt/sources.list.d/pve-no-subscription.list}"

# --- Pure functions (testable via source-guard) ---

# One suite per enabled enterprise entry, across every source file apt reads:
# the one-line format (/etc/apt/sources.list and *.list) and the DEB822 format
# (*.sources, which is what a PVE 9 install actually ships — Types:/URIs:/
# Suites: stanzas with no `deb` line in them at all).
oneline_enterprise_suites() {
    # A sources.list line is:  deb [<option> ...] <uri> <suite> [components]
    # so the suite is the field after the one holding the URI. Parsed by
    # position relative to the URI rather than by a fixed field number,
    # because `signed-by=` style options prepend fields and a hardcoded
    # index would then read an option as the suite.
    awk '/^[[:space:]]*deb[[:space:]]/ && /enterprise\.proxmox\.com/ {
        for (i = 1; i < NF; i++) {
            if ($i ~ /:\/\//) { print $(i + 1) }
        }
    }' "$@"
}

# One suite per enabled enterprise stanza. A stanza is enterprise when it names
# the host, and enabled unless it carries `Enabled: no` — stanzas are blank-
# line separated, and comment lines never count.
deb822_enterprise_suites() {
    awk '
        BEGIN { enterprise = 0; enabled = 1; suite = "" }
        function flush() {
            if (enterprise && enabled && suite != "") print suite
            enterprise = 0; enabled = 1; suite = ""
        }
        /^[[:space:]]*$/ { flush(); next }
        /^[[:space:]]*#/ { next }
        /enterprise\.proxmox\.com/ { enterprise = 1 }
        /^[[:space:]]*[Ee]nabled:[[:space:]]*(no|false|0)([[:space:]]|$)/ { enabled = 0 }
        /^[[:space:]]*Suites:/ {
            line = $0
            sub(/^[^:]*:/, "", line)
            n = split(line, parts, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
                if (parts[i] != "") { suite = parts[i]; break }
            }
        }
        END { flush() }
    ' "$@"
}

enterprise_suites() {
    # Every enabled enterprise entry on the host, one suite per line. Both
    # formats, and every file apt reads — the installer scatters them across
    # sources.list and sources.list.d, and only entries that are actually
    # enabled can produce the 401 that kills apt-get update.
    #
    # Always exits 0: emptiness is communicated through empty output, and the
    # caller reads this in a command substitution, where a nonzero status
    # would abort it under `set -e` — including on a host with no enterprise
    # entries at all, which is the normal no-op case.
    local f
    for f in "$APT_SOURCES_LIST" "$APT_SOURCES_DIR"/*.list; do
        [ -f "$f" ] || continue
        oneline_enterprise_suites "$f"
    done
    for f in "$APT_SOURCES_DIR"/*.sources; do
        [ -f "$f" ] || continue
        deb822_enterprise_suites "$f"
    done
    return 0
}

# The files holding at least one enabled enterprise entry: the ones to move
# aside. A file whose enterprise entries are all commented out (one-line) or
# carry `Enabled: no` (DEB822) is already inert and is left alone, which is
# what makes re-runs a no-op. Always exits 0 for the same command-substitution
# reason as enterprise_suites above.
enterprise_files() {
    local f suites
    for f in "$APT_SOURCES_LIST" "$APT_SOURCES_DIR"/*.list; do
        [ -f "$f" ] || continue
        suites="$(oneline_enterprise_suites "$f")"
        [ -n "$suites" ] && printf '%s\n' "$f"
    done
    for f in "$APT_SOURCES_DIR"/*.sources; do
        [ -f "$f" ] || continue
        suites="$(deb822_enterprise_suites "$f")"
        [ -n "$suites" ] && printf '%s\n' "$f"
    done
    return 0
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
    local files suites suite
    files="$(enterprise_files)"
    if [ -z "$files" ]; then
        log "No enterprise repositories enabled — nothing to do"
        return 0
    fi

    suites="$(enterprise_suites | sort -u)"
    if [ -z "$suites" ]; then
        die "enterprise repository files found but no suite could be read from them; refusing to guess"
    fi
    if [ "$(printf '%s\n' "$suites" | wc -l)" -gt 1 ]; then
        die "enterprise repositories name multiple suites ($(printf '%s' "$suites" | tr '\n' ' ')); refusing to guess"
    fi
    suite="$suites"

    log "Enterprise repositories are enabled but return 401 without a subscription."
    log "  Using the no-subscription repository for suite '${suite}'."

    # Moved aside rather than deleted or edited in place, uniformly across both
    # source formats: apt ignores any file not ending in .list or .sources, so
    # the originals stop counting while staying recoverable — restoring a
    # subscription is moving them back. Editing in place would need two
    # different edits (commenting lines vs. adding `Enabled: no` stanzas) for
    # the same outcome.
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mv "$f" "$f.disabled"
        log "  Disabled ${f} (moved aside; move it back for a subscription)"
    done <<< "$files"

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
