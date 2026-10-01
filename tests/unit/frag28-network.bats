#!/usr/bin/env bats
# tests/unit/frag28-network.bats — the upstream-connectivity gate.
#
# frag/28 reconfigures the LAN NIC, so its DHCP lease is renewing when the
# fragment runs: the first apt call races it and fails on every repository at
# once. wait_for_upstream gates on a default route plus a working resolver
# instead. The e2e suite exercises the passing branch against the full run;
# this file pins the two failing branches, which would each take the 120s
# timeout with a real sleep — hence the stubbed one.

load '../lib/helpers'

FRAG28="${PROJECT_ROOT}/provision/host/frag/28-network.sh"
E2E_STUBS="${PROJECT_ROOT}/tests/e2e/stubs"

setup() {
    # Unique per test: BATS_TMPDIR is shared across this file.
    WORK="$(mktemp -d)"
    MOCKBIN="${WORK}/mockbin"
    mkdir -p "$MOCKBIN"
    for stub in ip getent sleep date; do
        cp "${E2E_STUBS}/${stub}" "$MOCKBIN/$stub"
    done
    # chmod and grep are pure filesystem/text utilities, not system state:
    # the gate needs grep for its probes, and the isolation here is about
    # route/DNS presence, which neither affects.
    cp "$(command -v chmod)" "$MOCKBIN/chmod"
    cp "$(command -v grep)" "$MOCKBIN/grep"
    chmod +x "$MOCKBIN"/*
    # Functions read ROOT once, at source time, so the scratch root must be
    # in place before sourcing. log() goes to stdout for message assertions.
    export PVE_ROOT="${WORK}/root"
    mkdir -p "${WORK}/root"
    source "$FRAG28"
    log() { printf '%s\n' "$*"; }
}

teardown() {
    unset PVE_ROOT
    rm -rf "$WORK"
}

run_gate() {
    # Absolute bash: env -i clears PATH before resolving the interpreter.
    # log() is replaced after sourcing so messages go to stdout instead of
    # the host's /var/log, which is neither writable nor relevant here.
    env -i PATH="$MOCKBIN" FRAG28="$FRAG28" TIMEOUT="$1" \
        /bin/bash -c 'source "$FRAG28"; log() { printf "%s\n" "$*"; }; wait_for_upstream "$TIMEOUT"'
}

run_renew() {
    # Fully isolated PATH: whether the developer machine has aa-complain
    # installed must not change which branch runs.
    env -i PATH="$MOCKBIN" FRAG28="$FRAG28" \
        /bin/bash -c 'source "$FRAG28"; log() { printf "%s\n" "$*"; }; ensure_dhcp_renewals'
}

@test "a routed host with working DNS passes immediately" {
    run run_gate 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"upstream connectivity confirmed"* ]]
}

@test "a host with no default route waits out the timeout and dies loudly" {
    printf '#!/bin/bash\nexit 1\n' > "$MOCKBIN/ip"
    chmod +x "$MOCKBIN/ip"
    run run_gate 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no upstream connectivity"* ]]
}

@test "a host with no working resolver waits out the timeout and fails loudly" {
    printf '#!/bin/bash\nexit 2\n' > "$MOCKBIN/getent"
    chmod +x "$MOCKBIN/getent"
    run run_gate 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"no upstream connectivity"* ]]
}

write_lease() {
    mkdir -p "${WORK}/root/var/lib/dhcp"
    cat > "${WORK}/root/var/lib/dhcp/dhclient.eno1.leases"
}

@test "upstream resolvers are built from the DHCP lease" {
    write_lease <<'EOF'
lease {
  interface "eno1";
  fixed-address 192.168.14.52;
  option subnet-mask 255.255.255.0;
  option routers 192.168.14.1;
  option domain-name-servers 192.168.14.254, 192.168.14.253;
  option dhcp-lease-time 14400;
}
EOF
    run populate_upstream_resolvers
    [ "$status" -eq 0 ]
    run cat "${WORK}/root/run/resolv.conf"
    [[ "$output" == *"nameserver 192.168.14.254"* ]]
    [[ "$output" == *"nameserver 192.168.14.253"* ]]
}

@test "no lease files means no resolvers and a loud abort" {
    run populate_upstream_resolvers
    [ "$status" -ne 0 ]
    [[ "$output" == *"no upstream name servers"* ]]
}

@test "a lease without name servers aborts instead of starting dnsmasq deaf" {
    write_lease <<'EOF'
lease {
  interface "eno1";
  fixed-address 192.168.14.52;
  option subnet-mask 255.255.255.0;
  option routers 192.168.14.1;
}
EOF
    run populate_upstream_resolvers
    [ "$status" -ne 0 ]
    [[ "$output" == *"no upstream name servers"* ]]
}

@test "complain-mode is set when the tooling exists" {
    printf '#!/bin/bash\nexit 0\n' > "$MOCKBIN/aa-complain"
    chmod +x "$MOCKBIN/aa-complain"
    run run_renew
    [ "$status" -eq 0 ]
    [[ "$output" == *"complain mode"* ]]
}

@test "a missing aa-complain warns instead of aborting" {
    run run_renew
    [ "$status" -eq 0 ]
    [[ "$output" == *"aa-complain not installed"* ]]
}

@test "soliciting uses dhclient with the LAN NIC when present" {
    cat > "$MOCKBIN/dhclient" <<'EOF'
#!/bin/bash
printf 'dhclient %s\n' "$*" >> "${E2E_STATE:?}/dhcp-journal"
exit 0
EOF
    chmod +x "$MOCKBIN/dhclient"
    export E2E_STATE="$WORK/state"
    mkdir -p "$E2E_STATE"
    run env -i PATH="$MOCKBIN" FRAG28="$FRAG28" NIC="enp0s31f6" E2E_STATE="$E2E_STATE" \
        /bin/bash -c 'source "$FRAG28"; log() { printf "%s\n" "$*"; }; solicit_dhcp "$NIC"'
    [ "$status" -eq 0 ]
    run grep -q "dhclient enp0s31f6" "$E2E_STATE/dhcp-journal"
}

@test "soliciting fails loudly with no DHCP client installed" {
    run env -i PATH="$MOCKBIN" FRAG28="$FRAG28" NIC="enp0s31f6" \
        /bin/bash -c 'source "$FRAG28"; log() { printf "%s\n" "$*"; }; solicit_dhcp "$NIC"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"no DHCP client found"* ]]
}
