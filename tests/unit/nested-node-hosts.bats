#!/usr/bin/env bats
# tests/unit/nested-node-hosts.bats — the node's hosts entry tracks DHCP
#
# No reservations exist on this LAN, so a statically written node address
# rots on every lease change and pmxcfs refuses the next reboot. One script
# owns the truth: frag/90 calls --print-ip for the initial file (strict),
# cron and the lease-watcher call update mode (tolerant). The mock ip serves
# whatever $MOCK_ADDR holds, so staleness is just a second call with a new
# address — no network, no clock, no fixtures on disk beyond a hosts file.

load '../lib/helpers'

SCRIPT="${PROJECT_ROOT}/provision/host/nested-node-hosts.sh"

setup() {
    setup_mock_path
    WORK="$(mktemp -d)"
    export PVE_ROOT="$WORK"
    mkdir -p "${WORK}/var/log" "${WORK}/etc"
    cat > "${WORK}/etc/hosts" <<'EOF'
127.0.0.1       localhost

192.168.14.99 lychee-host.wolfskeep.com lychee-host

# VM static entries (MACs match frag/30 qm create --net0)
192.168.100.100 lychee.wolfskeep.com lychee
EOF
    cat > "${FIXTURES_DIR}/mock-bin/ip" <<'EOF'
#!/bin/bash
# Mock ip: link topology is fixed, the eno1 address follows $MOCK_ADDR.
# Empty $MOCK_ADDR means no lease yet (boot race): no inet line at all.
if printf '%s\n' "$@" | grep -q "\<link\>"; then
    printf '1: lo: <LOOPBACK,UP> mtu 6556\n'
    printf '2: eno1: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
    printf '3: vmbr0: <BROADCAST,MULTICAST,UP> mtu 1500 state UP\n'
    exit 0
fi
if printf '%s\n' "$@" | grep -q "\<addr\>"; then
    printf '3: vmbr0    inet 192.168.100.1/24 scope global vmbr0\n'
    if [ -n "${MOCK_ADDR:-}" ]; then
        printf '2: eno1    inet %s/24 brd 192.168.14.255 scope global dynamic eno1\n' "$MOCK_ADDR"
    fi
    exit 0
fi
exit 0
EOF
    chmod +x "${FIXTURES_DIR}/mock-bin/ip"
    export MOCK_ADDR="192.168.14.52"
}

teardown() {
    unset PVE_ROOT MOCK_ADDR
    rm -rf "$WORK"
    cleanup_mocks
}

@test "--print-ip prints the detected LAN address" {
    run bash "$SCRIPT" --print-ip
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.14.52" ]
}

@test "--print-ip dies with no address to print" {
    MOCK_ADDR=""
    export MOCK_ADDR
    run bash "$SCRIPT" --print-ip
    [ "$status" -ne 0 ]
}

@test "update mode rewrites a stale node line and preserves the rest" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_file_contains "${WORK}/etc/hosts" \
        "192.168.14.52 lychee-host.wolfskeep.com lychee-host"
    assert_file_contains "${WORK}/etc/hosts" \
        "192.168.100.100 lychee.wolfskeep.com lychee"
    run grep -c "192.168.14.99" "${WORK}/etc/hosts"
    [ "$output" = "0" ]
}

@test "update mode is a no-op when the entry is already correct" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local before after
    before="$(cat "${WORK}/etc/hosts")"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    after="$(cat "${WORK}/etc/hosts")"
    [ "$before" = "$after" ]
}

@test "update mode tracks a changed lease" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    MOCK_ADDR="192.168.14.77"
    export MOCK_ADDR
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_file_contains "${WORK}/etc/hosts" \
        "192.168.14.77 lychee-host.wolfskeep.com lychee-host"
}

@test "update mode warns instead of dying with no lease yet" {
    MOCK_ADDR=""
    export MOCK_ADDR
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_file_contains "${WORK}/etc/hosts" "192.168.14.99"
}

@test "update mode adds a missing node line" {
    grep -v "lychee-host.wolfskeep" "${WORK}/etc/hosts" \
        > "${WORK}/etc/hosts.tmp"
    mv "${WORK}/etc/hosts.tmp" "${WORK}/etc/hosts"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    assert_file_contains "${WORK}/etc/hosts" \
        "192.168.14.52 lychee-host.wolfskeep.com lychee-host"
}
