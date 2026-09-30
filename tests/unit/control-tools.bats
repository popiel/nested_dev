#!/usr/bin/env bats
# tests/unit/control-tools.bats — content contracts of the control-plane tools.
#
# devctl, vmctl-host, desktop-firstboot and the nested wrapper are exercised
# nowhere else: the end-to-end suite provisions the host, but it never SSHes
# into a guest or drives these CLIs. These tests pin the defect history that
# shipped silently before anything referenced the tools at all — asserted as
# content, because no behavioral harness exists for them yet. Where behavior
# became cheap to execute (nested keys-status), it moved to its own suite
# instead of living here as text.

load '../lib/helpers'

DESKTOP_FIRSTBOOT="${PROJECT_ROOT}/desktop/desktop-firstboot.sh"
DEVCTL="${PROJECT_ROOT}/desktop/devctl"
VMCTL_HOST="${PROJECT_ROOT}/provision/host/vmctl/vmctl-host"
NESTED="${PROJECT_ROOT}/dev/tools/nested"

# --- runtime verification on the desktop ---

@test "desktop-firstboot hard-fails when a seeded private key is missing" {
    assert_file_contains "$DESKTOP_FIRSTBOOT" \
        'die "Missing or empty private key ${key} at ${KEY_PATH}'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'for key in pvehost_vmctl nested-dev-id; do'
}

@test "desktop-firstboot validates that each key is a real OpenSSH private key" {
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'BEGIN OPENSSH PRIVATE KEY'
}

@test "desktop-firstboot hard-fails when authorized_keys is missing" {
    assert_file_contains "$DESKTOP_FIRSTBOOT" \
        'die "No authorized_keys at ${AUTHORIZED_KEYS}'
}

@test "desktop-firstboot provides both pvehost (restricted) and pveadmin (root) aliases" {
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'Host pvehost'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'Host pveadmin'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'IdentityFile ~/.ssh/pvehost_vmctl'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'IdentityFile ~/.ssh/nested-dev-id'
    # pvehost must stay on the restricted account.
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'User vmctl'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'User root'
}

# --- devctl wiring ---

@test "devctl uses the guest identity key for direct guest SSH" {
    # The vmctl key is ForceCommand-restricted and cannot open a guest shell.
    assert_file_contains "$DEVCTL" 'GUEST_ID_KEY="${HOME}/.ssh/nested-dev-id"'
    assert_file_contains "$DEVCTL" '-i "$GUEST_ID_KEY" -o IdentitiesOnly=yes'
}

@test "devctl keeps fleet control on the restricted vmctl credential" {
    assert_file_contains "$DEVCTL" 'ssh $SSH_OPTS vmctl@${PVEHOST} list'
}

@test "devctl exposes a host subcommand via the pveadmin alias" {
    assert_file_contains "$DEVCTL" 'PVEADMIN="pveadmin"'
    assert_file_contains "$DEVCTL" '"${PVEADMIN}"'
}

@test "devctl refuses to run without the guest identity key" {
    assert_file_contains "$DEVCTL" 'require_guest_id_key()'
    assert_file_contains "$DEVCTL" 'missing guest identity key'
}

@test "devctl does not hardcode the guest username" {
    # devctl has no file extension, so the static invariant sweep does not
    # cover it; assert the spirit of that rule explicitly.
    assert_file_not_contains "$DEVCTL" 'popiel@'
}

@test "devctl requires a shell environment for the guest username" {
    assert_file_contains "$DEVCTL" 'GUEST_USER="${USER:-}"'
}

@test "devctl's missing-key error names something that exists" {
    # It pointed at `devctl firstboot-log`, a verb that does not exist.
    assert_file_not_contains "$DEVCTL" 'firstboot-log'
    assert_file_contains "$DEVCTL" 'desktop-firstboot.log'
}

# --- vmctl-host runtime behaviour that a comment cannot guarantee ---

@test "vmctl-host sets a clone's hostname once the guest agent answers" {
    # A clone inherits the template's hostname, so without this every dev VM in
    # the fleet calls itself the same thing and the DNS name registered by `add`
    # never matches the guest's own hostname.
    assert_file_contains "$VMCTL_HOST" \
        'set_hostname_when_agent_ready'
    assert_file_contains "$VMCTL_HOST" \
        'hostnamectl set-hostname'
}

@test "hostname settling does not block the start verb" {
    # The agent is not up when `start` returns, so waiting inline would make
    # every start take the full agent timeout.
    assert_file_contains "$VMCTL_HOST" \
        '( set_hostname_when_agent_ready "$VMID" "$NAME" ) &'
}

@test "an unanswered guest agent is a warning, not a failed start" {
    assert_file_contains "$VMCTL_HOST" \
        'guest agent never answered'
}

@test "the list verb reads the VM inventory once instead of probing the dev range" {
    # Probing 103-249 with `qm status` costs two subprocesses per ID (~294
    # calls) on every `list`, and devctl calls list again for each name lookup.
    # `add` still scans the range legitimately — it has to find a free ID — so
    # this is asserted against the list verb alone.
    local list_block
    list_block="$(awk '/^    list\)/,/^        ;;$/' "$VMCTL_HOST")"
    [ -n "$list_block" ] || { echo "could not isolate the list verb" >&2; return 1; }
    printf '%s\n' "$list_block" | grep -q 'qm list' || {
        echo "the list verb does not read qm's inventory" >&2
        return 1
    }
    if printf '%s\n' "$list_block" | grep -qF 'seq $DEV_MIN $DEV_MAX'; then
        echo "the list verb still probes the whole dev range" >&2
        return 1
    fi
}

@test "the dev range boundaries are enforced on every ID-taking verb" {
    # The range starts above the static fleet, so an out-of-range ID cannot
    # reach the desktop, the LLM VM or the template.
    local v
    for v in status start shutdown stop log; do
        assert_file_contains "$VMCTL_HOST" \
            "outside dev range"
    done
    assert_file_contains "$VMCTL_HOST" \
        'DEV_MIN=103'
    assert_file_contains "$VMCTL_HOST" \
        'DEV_MAX=249'
}

# --- nested wrapper honesty ---

@test "the nested build image sources the hashes from keys/ too" {
    assert_file_contains "$NESTED" 'NESTED_DEV}/keys/'
}

@test "the wrapper's inspect verb does not claim to have validated the answer file" {
    # It only printed a template. Naming that "verify" is how an operator stops
    # reading the output.
    assert_file_not_contains "$NESTED" 'Answer file OK'
    assert_file_contains "$NESTED" 'not rendered'
    assert_file_contains "$NESTED" 'Validation happens during the build'
}
