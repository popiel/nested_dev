#!/usr/bin/env bats
# tests/unit/frag05-apt-repos.bats — apt usability before anything depends on it
#
# A PVE host without a subscription has /etc/apt/sources.list.d/pve-enterprise.list
# enabled, and enterprise.proxmox.com answers 401. apt-get update then exits
# non-zero, and because every fragment runs under `set -euo pipefail` the first
# one to call it dies.
#
# On a real host that surfaced as a memory/swap failure and no guests: frag/20
# died on its first command, provision-host.sh aborted the run on the first
# failing fragment, and frag/25 and frag/30 never executed. The error named a
# repository, three fragments away from anything to do with repositories.
#
# These are the fragment's pure functions and its main() contract. Whether the
# repair happens before anything needs apt is not pinned here — it emerges in
# tests/e2e/provision.bats, where the apt stub answers 401 for as long as the
# enterprise list is enabled, so any premature apt call fails the run.

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

    APT_DIR="${BATS_TMPDIR}/apt"
    ENTERPRISE_LIST="${APT_DIR}/pve-enterprise.list"
    NOSUB_LIST="${APT_DIR}/pve-no-subscription.list"
    mkdir -p "$APT_DIR"
}

teardown() {
    cleanup_mocks
}

# A PVE 9.2 / trixie host as the installer actually leaves it.
write_enterprise_list() {
    cat > "$ENTERPRISE_LIST" <<'EOF'
# PVE repository
deb http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
# Ceph
deb http://enterprise.proxmox.com/debian/ceph-squid trixie enterprise
EOF
}

@test "the suite is read out of the enterprise file, not hardcoded" {
    # PVE moves to a new Debian release periodically. A hardcoded suite is
    # wrong the day that happens, and cannot be fixed without editing code on
    # every host.
    write_enterprise_list
    run detect_suite
    [ "$output" = "trixie" ]
}

@test "the suite is read correctly from an https enterprise list" {
    cat > "$ENTERPRISE_LIST" <<'EOF'
deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
    run detect_suite
    [ "$output" = "bookworm" ]
}

@test "the suite is read through signed-by options" {
    # PVE ships the enterprise list with a keyring option on the line. Parsed by
    # field position instead of relative to the URI, that option is read as the
    # suite and the no-subscription repository is written for a nonexistent
    # distribution — which fails with 404 and looks like the same 401 all over
    # again.
    cat > "$ENTERPRISE_LIST" <<'EOF'
deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://enterprise.proxmox.com/debian/pve trixie pve-enterprise
EOF
    run detect_suite
    [ "$output" = "trixie" ]
}

@test "a commented-out line does not supply the suite" {
    # Second run of an idempotent fragment: the first run commented the lines
    # out. Reading the suite from them anyway would rewrite the file with a
    # suite no enabled entry mentions.
    write_enterprise_list
    sed -i 's/^\([[:space:]]*deb[[:space:]]\)/# \1/' "$ENTERPRISE_LIST"
    run detect_suite
    [ -z "$output" ]
}

@test "an enabled enterprise list is detected" {
    write_enterprise_list
    run enterprise_repos_enabled
    [ "$status" -eq 0 ]
}

@test "a fully commented-out enterprise list is not treated as enabled" {
    # The fragment is idempotent, and the second run sees its own work. Without
    # this the second run would rewrite a file it had already disabled.
    write_enterprise_list
    run sed -i 's/^\([[:space:]]*deb[[:space:]]\)/# \1/' "$ENTERPRISE_LIST"
    run enterprise_repos_enabled
    [ "$status" -ne 0 ]
}

@test "a missing enterprise list is not treated as enabled" {
    run enterprise_repos_enabled
    [ "$status" -ne 0 ]
}

@test "main switches the host to the no-subscription repository" {
    write_enterprise_list
    # apt-get is mocked so the fragment is exercised end to end without
    # touching this machine's package state.
    create_mock apt-get 'exit 0'
    run main
    [ "$status" -eq 0 ]

    # the enterprise entries are no longer active...
    run grep -c '^deb ' "$ENTERPRISE_LIST"
    [ "$output" -eq 0 ]
    # ...and the no-subscription repository is in place for the detected suite
    run cat "$NOSUB_LIST"
    [[ "$output" == *"deb http://download.proxmox.com/debian/pve trixie pve-no-subscription"* ]]
}

@test "main is a no-op when the enterprise repositories are already disabled" {
    # The fragment is idempotent, and the second run of a host's first boot
    # sees its own work. Without this it would rewrite the file every time and
    # log a change it had not made.
    write_enterprise_list
    sed -i 's/^\([[:space:]]*deb[[:space:]]\)/# \1/' "$ENTERPRISE_LIST"
    create_mock apt-get 'exit 1'
    run main
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to do"* ]]
}

@test "main aborts when apt still fails after the switch" {
    # A 404 on a wrong suite, or a network outage, must not be reported as a
    # successful repository setup: every later fragment would then die on its
    # own apt call with the real cause buried.
    write_enterprise_list
    create_mock apt-get 'exit 100'
    run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"apt-get update still fails"* ]]
}

@test "main refuses to guess a suite it cannot read" {
    # An enterprise list that is enabled but carries no parseable URI is not a
    # licence to write a repository line for a distribution we invented.
    # A bare `deb` would not do: it fails the enabled check, so main would take
    # the "nothing to do" path and the die would never be reached.
    cat > "$ENTERPRISE_LIST" <<'EOF'
deb trixie pve-enterprise
EOF
    create_mock apt-get 'exit 0'
    run main
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to guess"* ]]
}
