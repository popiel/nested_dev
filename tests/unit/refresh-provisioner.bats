#!/usr/bin/env bats
# tests/unit/refresh-provisioner.bats — updating the tree on an installed host
#
# Refreshing the provisioning tree on an installed host (new seeds, new
# firewall rules) used to be a hand-rolled fetch-and-swap pasted from memory.
# That sequence gets three things wrong: it runs the on-host copy without
# refetching (stale tree), it re-runs without removing the completion marker
# (the provisioner no-ops with "already completed provisioning"), and it swaps
# in an archive it never verified. refresh-provisioner.sh exists so the
# routine operation is one tested script: fetch, verify, swap, unlock, run.
#
# These tests drive the real script against a scratch PVE_ROOT with tarballs
# built on the fly, so the verify-swap-run path is the production code, not a
# reimplementation. REFRESH_TARBALL_SRC keeps every test hermetic: no test
# touches the network, and a test that needed it would fail loudly rather
# than reach out.

load '../lib/helpers'

SCRIPT="${PROJECT_ROOT}/provision/host/refresh-provisioner.sh"

setup() {
    setup_mock_path
    unset REFRESH_TARBALL_SRC REFRESH_REPO REFRESH_REF
    WORK="$(mktemp -d)"
    mkdir -p "${WORK}/root"
    export PVE_ROOT="$WORK"
    LIVE="${WORK}/root/provision"
    mkdir -p "${LIVE}/host" "${LIVE}/keys" "${WORK}/var/lib/pve-firstboot"
    # The live tree the refresh must replace, and the marker proving a
    # previous run completed (without unlocking, the provisioner no-ops).
    printf 'PERSONALIZATION_REPO="test/repo"\nPERSONALIZATION_REF="testref"\n' \
        > "${LIVE}/personalization.sh"
    echo "old tree" > "${LIVE}/old-tree-sentinel"
    echo "OLDKEY" > "${LIVE}/keys/host_os_ed25519.pub"
    date -Is > "${WORK}/var/lib/pve-firstboot/complete"
}

teardown() {
    unset PVE_ROOT REFRESH_TARBALL_SRC REFRESH_REPO REFRESH_REF
    rm -rf "$WORK"
    cleanup_mocks
}

# Build a fake fetched tree and pack it. The top-level name is deliberately
# NOT codeload-shaped, so passing proves the script derives it from the
# archive rather than guessing it from the branch.
make_tarball() {
    local name="$1" with_provisioner="$2" with_keys="$3"
    local tree="${WORK}/faketree-xyz"
    rm -rf "$tree"
    mkdir -p "${tree}/provision/host" "${tree}/keys"
    if [ "$with_provisioner" -eq 1 ]; then
        cat > "${tree}/provision/host/provision-host.sh" <<EOF
#!/usr/bin/env bash
echo "provisioner ran" >> "${WORK}/provisioner-ran"
date -Is > "${WORK}/var/lib/pve-firstboot/complete"
EOF
    fi
    if [ "$with_keys" -eq 1 ]; then
        echo "NEWKEY" > "${tree}/keys/host_os_ed25519.pub"
    fi
    echo "new tree" > "${tree}/provision/new-tree-sentinel"
    tar -czf "${WORK}/new.tar.gz" -C "$WORK" faketree-xyz
    printf '%s\n' "${WORK}/new.tar.gz"
}

@test "a refresh swaps the tree, preserves keys, runs the provisioner, and re-completes" {
    local tarball
    tarball="$(make_tarball x 1 1)"
    REFRESH_TARBALL_SRC="$tarball"
    export REFRESH_TARBALL_SRC
    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

    # The provisioner actually ran (not a marker no-op).
    [ -f "${WORK}/provisioner-ran" ] || { echo "provisioner never ran" >&2; return 1; }
    # The new tree is live, the old one retained as .old, nothing half-replaced.
    [ -f "${LIVE}/new-tree-sentinel" ] || { echo "new tree not in place" >&2; return 1; }
    [ ! -e "${LIVE}/old-tree-sentinel" ] || { echo "old tree still live" >&2; return 1; }
    [ -f "${LIVE}.old/old-tree-sentinel" ] || { echo "old tree not retained as .old" >&2; return 1; }
    # The archive's key reached the place frag/30 reads it from.
    [ "$(cat "${LIVE}/keys/host_os_ed25519.pub")" = "NEWKEY" ] || {
        echo "keys pubkey not preserved from the archive" >&2; return 1
    }
    # The run completed and says so.
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || { echo "no completion marker" >&2; return 1; }
    [[ "$output" == *"complete"* ]] || { echo "no completion summary" >&2; return 1; }
}

@test "a failed fetch leaves the live tree untouched and still marked complete" {
    REFRESH_TARBALL_SRC="${WORK}/does-not-exist.tar.gz"
    export REFRESH_TARBALL_SRC
    run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "a missing tarball reported success" >&2; return 1; }
    [ -f "${LIVE}/old-tree-sentinel" ] || { echo "live tree disturbed" >&2; return 1; }
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || { echo "marker removed despite no fetch" >&2; return 1; }
    [ ! -e "${LIVE}.old" ] || { echo ".old created with nothing to keep" >&2; return 1; }
}

@test "an archive without a provisioner is rejected before the swap" {
    local tarball
    tarball="$(make_tarball x 0 1)"
    REFRESH_TARBALL_SRC="$tarball"
    export REFRESH_TARBALL_SRC
    run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "a provisioner-less archive reported success" >&2; return 1; }
    [ -f "${LIVE}/old-tree-sentinel" ] || { echo "live tree swapped for a bad archive" >&2; return 1; }
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || { echo "marker removed for a rejected archive" >&2; return 1; }
    [[ "$output" == *"provision-host.sh"* ]] || { echo "failure does not name the missing file" >&2; return 1; }
}

@test "an archive without the keys pubkey is rejected before the swap" {
    # frag/30 aborts on the missing pubkey after everything else already
    # succeeded, so the archive must prove it carries the key first.
    local tarball
    tarball="$(make_tarball x 1 0)"
    REFRESH_TARBALL_SRC="$tarball"
    export REFRESH_TARBALL_SRC
    run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "a key-less archive reported success" >&2; return 1; }
    [ -f "${LIVE}/old-tree-sentinel" ] || { echo "live tree swapped for a bad archive" >&2; return 1; }
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || { echo "marker removed for a rejected archive" >&2; return 1; }
}

@test "a failing provisioner propagates its failure and leaves the run unlocked for retry" {
    local tree="${WORK}/faketree-xyz"
    rm -rf "$tree"
    mkdir -p "${tree}/provision/host" "${tree}/keys"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${tree}/provision/host/provision-host.sh"
    echo "NEWKEY" > "${tree}/keys/host_os_ed25519.pub"
    tar -czf "${WORK}/new.tar.gz" -C "$WORK" faketree-xyz
    REFRESH_TARBALL_SRC="${WORK}/new.tar.gz"
    export REFRESH_TARBALL_SRC
    run bash "$SCRIPT"
    [ "$status" -ne 0 ] || { echo "a failed provisioner reported success" >&2; return 1; }
    # The tree swap stands (fetch and verify passed) but no marker is written,
    # so fixing the cause and re-running proceeds instead of no-op'ing.
    [ ! -f "${WORK}/var/lib/pve-firstboot/complete" ] || {
        echo "a completion marker was written despite the failure" >&2; return 1
    }
}

@test "the real provisioner runs after unlock and re-writes the marker" {
    # The stub proves the plumbing; this proves the handoff to production
    # code. With the marker present and no unlock, the real provisioner would
    # no-op — a stamp from its fragment loop proves it ran.
    local tree="${WORK}/faketree-xyz"
    rm -rf "$tree"
    mkdir -p "${tree}/provision/host/frag" "${tree}/keys"
    cp "${PROJECT_ROOT}/provision/host/provision-host.sh" "${tree}/provision/host/provision-host.sh"
    printf '#!/usr/bin/env bash\necho "frag ran" >> "%s/frag-ran"\n' "$WORK" \
        > "${tree}/provision/host/frag/10-stamp.sh"
    echo "NEWKEY" > "${tree}/keys/host_os_ed25519.pub"
    tar -czf "${WORK}/new.tar.gz" -C "$WORK" faketree-xyz
    REFRESH_TARBALL_SRC="${WORK}/new.tar.gz"
    export REFRESH_TARBALL_SRC
    create_mock systemctl 'exit 0'

    run bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    [ -f "${WORK}/frag-ran" ] || {
        echo "the real provisioner no-op'd instead of running its fragments" >&2; return 1
    }
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || { echo "no completion marker" >&2; return 1; }
}
