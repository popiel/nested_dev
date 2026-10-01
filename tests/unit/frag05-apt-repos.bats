#!/usr/bin/env bats
# tests/unit/frag05-apt-repos.bats — apt usability before anything depends on it
#
# A PVE host without a subscription has enterprise repositories enabled, and
# enterprise.proxmox.com answers 401. apt-get update then exits non-zero, and
# because every fragment runs under `set -euo pipefail` the first one to call
# it dies.
#
# On a real host that surfaced as a memory/swap failure and no guests: frag/20
# died on its first command, provision-host.sh aborted the run on the first
# failing fragment, and frag/25 and frag/30 never executed. The error named a
# repository, three fragments away from anything to do with repositories.
#
# A second real host surfaced a blinder variant: the installer ships the
# enterprise repositories in DEB822 `.sources` format (Types:/URIs:/Suites:
# stanzas, no `deb` lines), which the one-line detector could not see at all —
# so the fragment reported "nothing to do" on a host whose apt was broken.
#
# These are the fragment's pure functions and its main() contract. Whether the
# repair happens before anything needs apt is not pinned here — it emerges in
# tests/e2e/provision.bats, where the apt stub answers 401 for as long as any
# enabled enterprise entry exists, so any premature apt call fails the run.

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/05-apt-repos.sh"
    # log and die are replaced so the fragment's decisions are observable in the
    # test output instead of going to /var/log/pve-firstboot.log. die exits
    # rather than returns: main calls it as a bare statement, so a non-zero
    # return would be discarded and main would carry on to report success.
    log() { printf '%s\n' "$*"; }
    die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

    # Unique per test: BATS_TMPDIR is shared across this file, and discovery
    # scans the whole directory — a previous test's enabled enterprise file
    # would leak into this test's results.
    APT_DIR="$(mktemp -d)"
    APT_SOURCES_DIR="$APT_DIR"
    APT_SOURCES_LIST="${APT_DIR}/sources.list"
    NOSUB_LIST="${APT_DIR}/pve-no-subscription.list"
    mkdir -p "$APT_DIR"
    : > "$APT_SOURCES_LIST"
}

teardown() {
    rm -rf "$APT_DIR"
    cleanup_mocks
}

# --- one-line format ---

@test "the suite is read out of a one-line enterprise entry, not hardcoded" {
    # PVE moves to a new Debian release periodically. A hardcoded suite is
    # wrong the day that happens, and cannot be fixed without editing code on
    # every host.
    cat > "$APT_DIR/pve.list" <<'EOF'
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    run oneline_enterprise_suites "$APT_DIR/pve.list"
    [ "$output" = "trixie" ]
}

@test "the suite is read through signed-by options" {
    # PVE ships these lines with a keyring option in front, and a positional
    # read would take the option as the suite and then write a no-subscription
    # repository for a nonexistent distribution — which fails with 404 and
    # looks like the same 401 all over again.
    cat > "$APT_DIR/pve.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    run oneline_enterprise_suites "$APT_DIR/pve.list"
    [ "$output" = "trixie" ]
}

@test "a commented-out line supplies no suite" {
    cat > "$APT_DIR/pve.list" <<'EOF'
# deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    run oneline_enterprise_suites "$APT_DIR/pve.list"
    [ -z "$output" ]
}

@test "a non-enterprise line supplies no suite" {
    # The installer puts plain Debian entries in the same directories. Reading
    # a suite out of one would write a no-subscription repository for Debian's
    # suite — usually right by accident, wrong the day it is not.
    cat > "$APT_DIR/debian.list" <<'EOF'
deb http://deb.debian.org/debian trixie main contrib
EOF
    run oneline_enterprise_suites "$APT_DIR/debian.list"
    [ -z "$output" ]
}

# --- DEB822 format ---

write_pve_sources() {
    cat > "$APT_DIR/pve-enterprise.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
}

@test "the suite is read out of a DEB822 enterprise stanza" {
    write_pve_sources
    run deb822_enterprise_suites "$APT_DIR/pve-enterprise.sources"
    [ "$output" = "trixie" ]
}

@test "every enabled enterprise stanza reports its suite" {
    cat > "$APT_DIR/two.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise

Types: deb
URIs: https://enterprise.proxmox.com/debian/ceph-squid
Suites: trixie
Components: enterprise
EOF
    run deb822_enterprise_suites "$APT_DIR/two.sources"
    [ "$output" = "trixie
trixie" ]
}

@test "a stanza with Enabled: no is not an enabled entry" {
    cat > "$APT_DIR/off.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
Enabled: no
EOF
    run deb822_enterprise_suites "$APT_DIR/off.sources"
    [ -z "$output" ]
}

@test "comments and blank lines do not confuse the stanza scan" {
    cat > "$APT_DIR/messy.sources" <<'EOF'
# PVE enterprise repository

Types: deb
# the mirror line:
URIs: https://enterprise.proxmox.com/debian/pve
Suites: trixie
Components: pve-enterprise
EOF
    run deb822_enterprise_suites "$APT_DIR/messy.sources"
    [ "$output" = "trixie" ]
}

@test "a non-enterprise stanza supplies no suite" {
    cat > "$APT_DIR/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
EOF
    run deb822_enterprise_suites "$APT_DIR/debian.sources"
    [ -z "$output" ]
}

# --- file discovery ---

@test "enterprise_files finds enabled entries in both formats" {
    cat > "$APT_DIR/a.list" <<'EOF'
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    write_pve_sources
    run enterprise_files
    [[ "$output" == *"$APT_DIR/a.list"* ]]
    [[ "$output" == *"$APT_DIR/pve-enterprise.sources"* ]]
}

@test "enterprise_files ignores inert and unrelated files" {
    cat > "$APT_DIR/off.list" <<'EOF'
# deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    cat > "$APT_DIR/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib
EOF
    run enterprise_files
    [ -z "$output" ]
}

# --- main() ---

@test "main moves enabled enterprise files aside and writes no-subscription" {
    cat > "$APT_DIR/a.list" <<'EOF'
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    write_pve_sources
    create_mock apt-get 'exit 0'
    run main
    [ "$status" -eq 0 ]

    # Moved aside, not deleted: restoring a subscription is moving them back.
    [ -f "$APT_DIR/a.list.disabled" ]
    [ -f "$APT_DIR/pve-enterprise.sources.disabled" ]
    [ ! -e "$APT_DIR/a.list" ]
    [ ! -e "$APT_DIR/pve-enterprise.sources" ]

    # ...and the no-subscription repository is in place for the detected suite.
    run grep -xF 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription' \
        "$NOSUB_LIST"
}

@test "main is a no-op when no enterprise entry is enabled" {
    # The fragment is idempotent, and the second run of a host's first boot
    # sees its own work: the first run moved the files to names apt ignores.
    cat > "$APT_DIR/pve-enterprise.list.disabled" <<'EOF'
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    create_mock apt-get 'exit 1'
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
}

@test "main aborts when apt still fails after the switch" {
    # A 404 on a wrong suite, or a network outage, must not be reported as a
    # successful repository setup: every later fragment would then die on its
    # own apt call with the real cause buried.
    write_pve_sources
    create_mock apt-get 'exit 100'
    run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"apt-get update still fails"* ]]
}

@test "main refuses to guess when suites disagree" {
    cat > "$APT_DIR/a.list" <<'EOF'
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    cat > "$APT_DIR/b.sources" <<'EOF'
Types: deb
URIs: https://enterprise.proxmox.com/debian/pve
Suites: bookworm
Components: pve-enterprise
EOF
    create_mock apt-get 'exit 0'
    run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"multiple suites"* ]]
}
