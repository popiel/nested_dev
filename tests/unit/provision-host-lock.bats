#!/usr/bin/env bats
# tests/unit/provision-host-lock.bats — one provisioning run at a time
#
# On a real host two pve-firstboot runs overlapped: the systemd oneshot that
# multi-user.target starts, and the direct call first-boot.sh makes so that
# provisioning happens on the first boot. frag/10 rebuilds the initramfs to bind
# passthrough devices, and two update-initramfs runs against one tree interleave
# their temporary files — one run failed with
# `mv: cannot stat /boot/initrd.img-7.0.2-6-pve.new` while the other succeeded.
#
# These tests run the real provisioner, concurrently, against a stub fragment
# that records overlap. The script itself is never modified: PVE_ROOT redirects
# its lock, marker and log into the test's scratch tree. Asserting that the
# source contains `flock` would pass against a lock placed where it never
# contends.

load '../lib/helpers'

setup() {
    setup_mock_path
    # Unique per test: BATS_TMPDIR is shared across this file, and a leftover
    # completion marker would turn a later test into a no-op.
    WORK="$(mktemp -d)"
    PROV_ROOT="${WORK}/prov"
    FRAG_DIR="${PROV_ROOT}/frag"
    mkdir -p "$FRAG_DIR"
    cp "${PROJECT_ROOT}/provision/host/provision-host.sh" "${PROV_ROOT}/provision-host.sh"
    LOG="${WORK}/var/log/pve-firstboot.log"
    mkdir -p "$(dirname "$LOG")"
    : > "$LOG"
    export PVE_ROOT="$WORK"
}

teardown() {
    unset PVE_ROOT
    rm -rf "$WORK"
    cleanup_mocks
}

# A fragment that detects whether another instance is inside the loop at the
# same moment, then holds the floor long enough for a race to be observable.
write_overlap_detecting_fragment() {
    cat > "${FRAG_DIR}/10-race.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
MARKER="${WORK}/in-flight"
: > "\$MARKER"
sleep 1
if [ -e "\$MARKER.2" ]; then
    echo "OVERLAP" >> "${WORK}/overlap"
fi
printf '%s\n' "\$\$" > "\$MARKER.2"
sleep 1
rm -f "\$MARKER" "\$MARKER.2"
EOF
}

@test "two concurrent runs do not overlap" {
    write_overlap_detecting_fragment
    create_mock systemctl 'exit 0'

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local first=$!
    # Start the second while the first is provably still inside the fragment.
    local waited=0
    while [ ! -e "${WORK}/in-flight" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -e "${WORK}/in-flight" ] || { echo "first run never entered the fragment" >&2; return 1; }

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local second=$!

    wait "$first" || { echo "first run failed" >&2; return 1; }
    wait "$second" || { echo "second run failed" >&2; return 1; }

    [ ! -e "${WORK}/overlap" ] || {
        echo "both runs were inside the fragment at the same time" >&2
        cat "${WORK}/overlap" >&2
        return 1
    }
}

@test "the second run waits rather than failing or claiming success early" {
    write_overlap_detecting_fragment
    create_mock systemctl 'exit 0'

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local first=$!
    local waited=0
    while [ ! -e "${WORK}/in-flight" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    bash "${PROV_ROOT}/provision-host.sh" > "${WORK}/second.out" 2>&1 &
    local second=$!
    wait "$first"
    wait "$second" || { echo "second run failed" >&2; return 1; }

    # It must report that another run did the work, not that it did the work.
    grep -q "already completed provisioning" "${WORK}/second.out" || {
        echo "the second run did not report deferring to the first:" >&2
        cat "${WORK}/second.out" >&2
        return 1
    }
}

@test "a run after a completed run is a no-op" {
    create_mock systemctl 'exit 0'
    # No fragment is installed that records anything, so this exercises the
    # marker path on its own.
    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ] || {
        echo "no completion marker was written" >&2
        return 1
    }
    run bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already completed provisioning"* ]]
}

@test "a failed run leaves no completion marker, so a retry proceeds" {
    # The marker is what makes a second run a no-op. Writing it on the failure
    # path would make the first failure permanent: every later attempt would
    # report success without having done anything.
    cat > "${FRAG_DIR}/10-fails.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    create_mock systemctl 'exit 0'

    run bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -ne 0 ]
    [ ! -f "${WORK}/var/lib/pve-firstboot/complete" ] || {
        echo "a completion marker was written despite the failure" >&2
        return 1
    }

    # Now fix the cause and confirm the retry actually runs the fragments.
    rm -f "${FRAG_DIR}/10-fails.sh"
    echo '#!/usr/bin/env bash' > "${FRAG_DIR}/10-fixed.sh"
    echo 'exit 0' >> "${FRAG_DIR}/10-fixed.sh"
    run bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -eq 0 ]
    [ -f "${WORK}/var/lib/pve-firstboot/complete" ]
}
