#!/usr/bin/env bats
# tests/unit/vmctl-create.bats — the create verb of the dev VM control plane.
#
# Behavioral tests drive the real vmctl-host with a stub qm (the ForceCommand
# channel is bypassed via argv, and root is bypassed via the suite-only
# VMCTL_ALLOW_NONROOT hatch, exactly like control-tools.bats). Anything that
# would write outside a stub (clone, dnsmasq reload, hosts/inventory writes)
# is asserted statically instead: the suite runs unprivileged and those paths
# need root.
#
# Static tests pin the clone contract as content: a created VM is stopped,
# named/derived deterministically, firewall-managed, registered atomically,
# and audited. A silent change to any of those is a fleet-integrity change.

load '../lib/helpers'

VMCTL_HOST="${PROJECT_ROOT}/provision/host/vmctl/vmctl-host"

setup() {
    BIN="$BATS_TEST_TMPDIR/vmctlc-bin"
    mkdir -p "$BIN"
    export QM_CALLS="$BIN/calls"
    : > "$QM_CALLS"
    cat > "$BIN/qm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${QM_CALLS:?}"
cmd="$1"
if [ "$cmd" = "status" ]; then
    # QM_EXIST=all makes every ID look taken (exhausted range); otherwise
    # only the IDs in QM_EXIST_IDS exist.
    if [ "${QM_EXIST:-}" = "all" ]; then
        exit 0
    fi
    case " ${QM_EXIST_IDS:-} " in
        *" $2 "*) exit 0 ;;
        *) exit 1 ;;
    esac
fi
exit 0
EOF
    chmod +x "$BIN/qm"
    export PATH="$BIN:/usr/bin:/bin"
    export VMCTL_ALLOW_NONROOT=1
    unset SSH_ORIGINAL_COMMAND
}

teardown() {
    unset QM_CALLS VMCTL_ALLOW_NONROOT
}

# Covers: R-07.4.1, R-07.2.4
@test "create rejects a bad project name before touching the hypervisor" {
    # The project name is the only operator free text reaching qm; anything
    # else must die on the pattern before the first hypervisor call.
    run bash "$VMCTL_HOST" create 'Bad Name!'
    [ "$status" -ne 0 ]
    assert_contains "$output" 'Project name must be lowercase'
    [ ! -s "$QM_CALLS" ] || {
        echo "rejected input still reached qm:" >&2
        cat "$QM_CALLS" >&2
        return 1
    }
}

# Covers: R-07.4.2, A-07.21
@test "create reports an exhausted dev range instead of reusing an ID" {
    # Every ID taken: the scan must end in an explicit error, never in an ID
    # outside the range and never in a silent reuse.
    export QM_EXIST=all
    run bash "$VMCTL_HOST" create validname
    [ "$status" -ne 0 ]
    assert_contains "$output" 'No free VMIDs'
}

# Covers: A-07.8
@test "an unknown verb is refused with usage, not a shell" {
    run bash "$VMCTL_HOST" frobnicate
    [ "$status" -ne 0 ]
    assert_contains "$output" 'Usage: <command> [args]'
}

# Covers: R-07.8.1, R-07.8.2, R-07.8.4
@test "accepted and refused operations are both logged with their class" {
    # The audit must distinguish control operations from one another and
    # refusals from accepts; die() is the single refusal channel.
    assert_file_contains "$VMCTL_HOST" 'log "CLONE '
    assert_file_contains "$VMCTL_HOST" 'log "START '
    assert_file_contains "$VMCTL_HOST" 'log "REJECT: '
    assert_file_contains "$VMCTL_HOST" '/var/log/nested-dev-vmctl.log'
}

# Covers: R-07.4.3, A-07.9
@test "a created VM is a stopped full clone, never started by create" {
    # Untrusted code must not boot on creation: clone with --full, and no
    # start call anywhere in the create block (only the operator's later
    # `start` boots it, settling the hostname then).
    assert_file_contains "$VMCTL_HOST" 'qm clone 102 "$NEXT_VID" --name "$FULLNAME" --full'
    assert_file_contains "$VMCTL_HOST" 'created and stopped. Start with: start'
    local block
    block="$(awk '/^    create\)/,/^        ;;$/' "$VMCTL_HOST")"
    [ -n "$block" ] || { echo "could not isolate the create verb" >&2; return 1; }
    if printf '%s\n' "$block" | grep -q 'qm start'; then
        echo "the create verb starts the VM it just cloned" >&2
        return 1
    fi
}

# Covers: R-07.4.4, R-07.5.1, A-07.9
@test "name, address, MAC and hostname derive from project and ID" {
    assert_file_contains "$VMCTL_HOST" 'FULLNAME="dev-${PROJECT}"'
    assert_file_contains "$VMCTL_HOST" 'IP="192.168.100.${NEXT_VID}"'
    assert_file_contains "$VMCTL_HOST" 'MAC="52:54:00:00:02:${MAC_SUFFIX}"'
    assert_file_contains "$VMCTL_HOST" 'HOSTNAME="lychee-${FULLNAME}"'
}

# Covers: R-07.4.5, R-07.4.6, R-07.4.7
@test "creation registers the VM atomically: lease, names, inventory" {
    # A VM that resolves by neither name is unreachable: the lease, both
    # resolutions and the inventory row land before success is reported, and
    # the name service reloads without waiting for a restart.
    assert_file_contains "$VMCTL_HOST" 'firewall=1'
    assert_file_contains "$VMCTL_HOST" 'dhcp-host=${MAC},${HOSTNAME},${IP}'
    assert_file_contains "$VMCTL_HOST" 'systemctl reload dnsmasq'
    assert_file_contains "$VMCTL_HOST" '/etc/hosts updated'
    assert_file_contains "$VMCTL_HOST" 'Inventory updated: VMID'
}
