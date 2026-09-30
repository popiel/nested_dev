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
# These tests run the provisioner for real, concurrently, against a stub fragment
# that records overlap. Asserting that the source contains `flock` would pass
# against a lock placed where it never contends.

load '../lib/helpers'

setup() {
    setup_mock_path
    PROV_ROOT="${BATS_TMPDIR}/prov"
    FRAG_DIR="${PROV_ROOT}/frag"
    mkdir -p "$FRAG_DIR"
    cp "${PROJECT_ROOT}/provision/host/provision-host.sh" "${PROV_ROOT}/provision-host.sh"
    LOG="${BATS_TMPDIR}/pve-firstboot.log"
    : > "$LOG"
}

teardown() {
    cleanup_mocks
}

# A fragment that detects whether another instance is inside the loop at the
# same moment, then holds the floor long enough for a race to be observable.
write_overlap_detecting_fragment() {
    cat > "${FRAG_DIR}/10-race.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
MARKER="${BATS_TMPDIR}/in-flight"
: > "\$MARKER"
sleep 1
if [ -e "\$MARKER.2" ]; then
    echo "OVERLAP" >> "${BATS_TMPDIR}/overlap"
fi
printf '%s\n' "\$\$" > "\$MARKER.2"
sleep 1
rm -f "\$MARKER" "\$MARKER.2"
EOF
}

# The paths are absolute and written by provision-host.sh, so they have to be
# overridden in a copy rather than by environment.
retarget_paths() {
    sed -e "s|^LOCK_FILE=.*|LOCK_FILE=\"${BATS_TMPDIR}/prov.lock\"|" \
        -e "s|^COMPLETE_MARKER=.*|COMPLETE_MARKER=\"${BATS_TMPDIR}/prov.complete\"|" \
        -e "s|^LOG=.*|LOG=\"$LOG\"|" \
        "${PROV_ROOT}/provision-host.sh" > "${PROV_ROOT}/provision-host.sh.new"
    mv "${PROV_ROOT}/provision-host.sh.new" "${PROV_ROOT}/provision-host.sh"
    rm -f "${BATS_TMPDIR}/overlap" "${BATS_TMPDIR}/prov.complete"
}

@test "two concurrent runs do not overlap" {
    write_overlap_detecting_fragment
    retarget_paths
    create_mock systemctl 'exit 0'

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local first=$!
    # Start the second while the first is provably still inside the fragment.
    local waited=0
    while [ ! -e "${BATS_TMPDIR}/in-flight" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -e "${BATS_TMPDIR}/in-flight" ] || { echo "first run never entered the fragment" >&2; return 1; }

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local second=$!

    wait "$first" || { echo "first run failed" >&2; return 1; }
    wait "$second" || { echo "second run failed" >&2; return 1; }

    [ ! -e "${BATS_TMPDIR}/overlap" ] || {
        echo "both runs were inside the fragment at the same time" >&2
        cat "${BATS_TMPDIR}/overlap" >&2
        return 1
    }
}

@test "the second run waits rather than failing or claiming success early" {
    write_overlap_detecting_fragment
    retarget_paths
    create_mock systemctl 'exit 0'

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1 &
    local first=$!
    local waited=0
    while [ ! -e "${BATS_TMPDIR}/in-flight" ] && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    bash "${PROV_ROOT}/provision-host.sh" > "${BATS_TMPDIR}/second.out" 2>&1 &
    local second=$!
    wait "$first"
    wait "$second" || { echo "second run failed" >&2; return 1; }

    # It must report that another run did the work, not that it did the work.
    grep -q "already completed provisioning" "${BATS_TMPDIR}/second.out" || {
        echo "the second run did not report deferring to the first:" >&2
        cat "${BATS_TMPDIR}/second.out" >&2
        return 1
    }
}

@test "a run after a completed run is a no-op" {
    retarget_paths
    create_mock systemctl 'exit 0'
    # No fragment is installed that records anything, so this exercises the
    # marker path on its own.
    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1
    [ -f "${BATS_TMPDIR}/prov.complete" ] || {
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
    retarget_paths
    create_mock systemctl 'exit 0'

    run bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TMPDIR}/prov.complete" ] || {
        echo "a completion marker was written despite the failure" >&2
        return 1
    }

    # Now fix the cause and confirm the retry actually runs the fragments.
    rm -f "${FRAG_DIR}/10-fails.sh"
    echo '#!/usr/bin/env bash' > "${FRAG_DIR}/10-fixed.sh"
    echo 'exit 0' >> "${FRAG_DIR}/10-fixed.sh"
    run bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -eq 0 ]
    [ -f "${BATS_TMPDIR}/prov.complete" ]
}
