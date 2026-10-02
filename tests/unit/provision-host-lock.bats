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
#
# A second incident shapes the last test: the lock used to be an fd held open
# for the whole run, and every daemon a fragment started inherited a copy.
# frag/28's dhclient daemons held it forever, so later runs hung with no
# provisioner running. The lock is now held by a waiting flock(1) parent while
# the script runs without the fd (--close).

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

@test "a daemon spawned by a fragment cannot hold the lock after the run" {
    # frag/28 starts dhclient daemons mid-run. Under the old fd-held lock each
    # one inherited a copy of the lock fd, and every later run hung on
    # acquisition with no provisioner running anywhere — fuser showed only
    # dhclient holding the file. This replays that shape with sleep standing in
    # for dhclient: if the daemon inherits the lock, the second run hangs and
    # timeout kills it.
    #
    # Flag and tool support are asserted, not assumed: without --close there is
    # no daemon-safe lock to test, and without timeout a regression would hang
    # the suite instead of failing it.
    command -v flock >/dev/null 2>&1 || { echo "no flock(1) — lock behavior untestable here" >&2; return 1; }
    flock --help 2>&1 | grep -q -- --close || { echo "flock(1) has no --close — lock behavior untestable here" >&2; return 1; }
    command -v timeout >/dev/null 2>&1 || { echo "no timeout(1) — a hang would hang the suite" >&2; return 1; }
    cat > "${FRAG_DIR}/10-daemon.sh" <<EOF
#!/usr/bin/env bash
echo "frag ran" >> "${WORK}/frag-runs"
# Appended, never overwritten: the second run re-executes this fragment and
# spawns again. An orphan from either run holds the suite-output pipe open
# until it dies, so every spawned pid is recorded and all are killed at the
# end — a single pidfile would leak the first orphan and stall the harness
# for the sleep's whole lifetime on every green run.
sleep 60 & echo \$! >> "${WORK}/daemon.pids"
exit 0
EOF
    create_mock systemctl 'exit 0'

    bash "${PROV_ROOT}/provision-host.sh" >/dev/null 2>&1
    [ -s "${WORK}/daemon.pids" ] || { echo "fragment did not spawn the daemon" >&2; return 1; }
    # A parked daemon must exist while the second run starts, or nothing about
    # inheritance is proven.
    kill -0 "$(tail -n 1 "${WORK}/daemon.pids")" 2>/dev/null || { echo "daemon already gone" >&2; return 1; }

    # Unlock exactly the way refresh-provisioner.sh does, then prove the next
    # run proceeds instead of hanging behind the daemon. The two-line count
    # proves it ran its fragments rather than no-op'ing on a surviving marker.
    rm -f "${WORK}/var/lib/pve-firstboot/complete"
    run timeout 30 bash "${PROV_ROOT}/provision-host.sh"
    [ "$status" -eq 0 ] || { echo "second run hung behind the daemon (or failed)" >&2; return 1; }
    [ "$(wc -l < "${WORK}/frag-runs" | tr -d ' ')" -eq 2 ] || {
        echo "second run did not execute its fragments" >&2; return 1
    }

    while read -r pid; do kill "$pid" 2>/dev/null || true; done < "${WORK}/daemon.pids"
}
