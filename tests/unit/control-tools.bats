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

@test "no first-boot script stops itself on completion" {
    # disable --now on the running service SIGTERMs it after the final log
    # line, so systemd records a completed run as failed. Disable only.
    local script
    for script in "${PROJECT_ROOT}/desktop/desktop-firstboot.sh" \
                  "${PROJECT_ROOT}/llm/llm-firstboot.sh" \
                  "${PROJECT_ROOT}/dev/dev-firstboot.sh"; do
        assert_file_not_contains "$script" 'disable --now desktop-firstboot'
        assert_file_not_contains "$script" 'disable --now llm-firstboot'
        assert_file_not_contains "$script" 'disable --now dev-firstboot'
    done
}

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

@test "desktop i3status config only uses modules i3status understands" {
    # i3bar kills a status_command that exits non-zero — on the live guest
    # that was a session with a dead bar and no obvious way to open windows,
    # from a single bad module name (net_all, rejected by i3status 2.15).
    # Behavior where possible: render the heredoc and run the real binary
    # briefly. A config error exits immediately; a good config runs until
    # killed (timeout 124).
    require_command i3status
    require_command timeout
    local cfg="${BATS_TMPDIR}/i3status-live.conf"
    sed -n "/<<'I3STATUS_EOF'$/,/^I3STATUS_EOF$/p" \
        "${DESKTOP_FIRSTBOOT}" | sed '1d;$d' > "$cfg"
    [ -s "$cfg" ] || { echo "i3status heredoc not found" >&2; return 1; }
    run timeout 3 i3status -c "$cfg"
    [ "$status" -eq 124 ] || { echo "$output" >&2; return 1; }
}

@test "keys/vnc-passwd.hash decodes to a valid 8-byte console secret" {
    # The hash is stored as printf-octal text so the repo never holds raw
    # bytes — and the decoded hex is itself a secret that must never appear
    # in a tracked file. So this pins the shape (valid octal escapes
    # decoding to exactly 8 bytes), never the value. A slip that changes
    # length or syntax fails here; the value itself is checked only at the
    # live viewer, the one place it is ever typed.
    if [ ! -f "${PROJECT_ROOT}/keys/vnc-passwd.hash" ]; then
        skip "keys/vnc-passwd.hash is local-only (gitignored)"
    fi
    run grep -E -q '^(\\[0-7]{3})+$' "${PROJECT_ROOT}/keys/vnc-passwd.hash"
    [ "$status" -eq 0 ]
    run bash -c 'printf "%b" "$(cat "$1")" | od -An -tx1 | tr -d " \n"' _ "${PROJECT_ROOT}/keys/vnc-passwd.hash"
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 16 ]
}

@test "desktop first-boot serves the VNC console mirror" {
    # R-02.2.1: the remote view must be the physical console session, which
    # xrdp can never provide (separate sessions by architecture). x11vnc
    # scrapes the live :0 instead, authenticated by the repo-pinned hash.
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'vnc-passwd.hash'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'x11vnc.service'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'WantedBy=graphical.target'
    # keys/vnc-passwd.hash is storepasswd *output*, so it is written raw and
    # served via -rfbauth; deriving a typed string plus -passwdfile would
    # serve a different password than the one the hash encodes.
    assert_file_contains "$DESKTOP_FIRSTBOOT" '-rfbauth /etc/x11vnc/passwd'
    assert_file_not_contains "$DESKTOP_FIRSTBOOT" 'passwdfile'
    # A connected x11vnc ignored SIGTERM for the full 90s default (observed
    # live: 85s stall to SIGKILL on shutdown, viewer attached throughout).
    # Bound the stop; the block site is undetermined and irrelevant to a
    # stateless mirror.
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'TimeoutStopSec=10'
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'to any port 5900'
    # DNAT preserves the client source IP, so a host-scoped ufw rule would
    # drop Filbert's traffic at the guest's default-deny (observed live:
    # host FORWARD admitted, guest ufw denied). Pin the LAN scope.
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'ufw allow from 192.168.14.0/24 to any port 5900'
}

@test "desktop ships no RDP stack" {
    # RDP is eliminated (R-02.2.1): no package, no unit, no firewall hole.
    # Pinned on functional strings, not the bare word — comments may still
    # name xrdp as the rationale for its absence.
    local seed="${PROJECT_ROOT}/desktop/user-data/user-data"
    assert_file_not_contains "$seed" 'xrdp'
    assert_file_not_contains "$seed" '3389'
    assert_file_not_contains "$DESKTOP_FIRSTBOOT" 'xorgxrdp'
    assert_file_not_contains "$DESKTOP_FIRSTBOOT" '3389'
    assert_file_not_contains "$DESKTOP_FIRSTBOOT" 'enable --now xrdp'
}

@test "desktop i3 mod key is Alt, not Super" {
    # VNC is the only input path and no Windows VNC client forwards Super,
    # so a Mod4 config leaves every $mod binding dead (observed live:
    # TightVNC swallows it). i3's upstream Mod1 default is the working one.
    assert_file_contains "$DESKTOP_FIRSTBOOT" 'set $mod Mod1'
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

@test "vmctl list reads every status from one qm list" {
    # The static entries once hardcoded "running" (a stopped 101 reported
    # running, observed live); the first fix probed each VM, which is still
    # one call per VM too many — qm list already carries VMID, NAME and
    # STATUS. Runs the real list verb with qm recording every invocation:
    # the only call may be `list`, and a dev-range row must resolve from the
    # same read.
    local bin="$BATS_TMPDIR/vmctl-qm-stub"
    mkdir -p "$bin"
    export QM_CALLS="$bin/calls"
    : > "$QM_CALLS"
    cat > "$bin/qm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${QM_CALLS:?}"
if [ "$1" = "list" ]; then
    printf '%s\n' \
        "VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID" \
        "100 desktop running 8192 40.00 123" \
        "101 llm stopped 16384 80.00 0" \
        "104 dev-proj running 4096 10.00 456"
fi
exit 0
EOF
    chmod +x "$bin/qm"
    # Direct execution (not source): no dependence on positional-parameter
    # inheritance or run-builtin semantics. The script reads the verb from
    # $@ when SSH_ORIGINAL_COMMAND is unset, and the stub qm rides an
    # explicitly exported PATH. Each bats test runs isolated, so the exports
    # cannot leak into neighboring tests. Deliberately no /usr/sbin here:
    # the ForceCommand channel carries none, and the script must be
    # self-sufficient (it appends the system dirs itself).
    unset SSH_ORIGINAL_COMMAND
    export PATH="$bin:/usr/bin:/bin"
    # The suite runs unprivileged; the hatch bypasses the root refusal below
    # (unreachable via SSH, so production keeps the trap armed).
    export VMCTL_ALLOW_NONROOT=1
    run bash "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" list
    [ "$status" -eq 0 ]
    local line100 line101 line104
    line100="$(printf '%s\n' "$output" | awk '$1 == "100"')"
    line101="$(printf '%s\n' "$output" | awk '$1 == "101"')"
    line104="$(printf '%s\n' "$output" | awk '$1 == "104"')"
    [ -n "$line100" ]
    [ -n "$line101" ]
    [ -n "$line104" ]
    [[ "$line100" == *"running" ]]
    [[ "$line101" == *"stopped" ]]
    [[ "$line101" != *"running" ]]
    [[ "$line104" == *"dev-proj"* ]]
    [[ "$line104" == *"running" ]]
    # No per-VM probing of any kind may have happened.
    ! grep -q "^status" "$QM_CALLS"
    ! grep -q "^config" "$QM_CALLS"
    unset QM_CALLS
}

@test "vmctl list degrades to unknown when qm is absent" {
    # No stub, no /usr/sbin: the ForceCommand channel. A runtime qm failure
    # must yield unknown rows and exit 0 — never the silent death of an
    # errexit abort after the header with empty stderr (observed live).
    unset SSH_ORIGINAL_COMMAND
    export PATH="/usr/bin:/bin"
    export VMCTL_ALLOW_NONROOT=1
    run bash "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" list
    [ "$status" -eq 0 ]
    local line100
    line100="$(printf '%s\n' "$output" | awk '$1 == "100"')"
    [ -n "$line100" ]
    [[ "$line100" == *"unknown" ]]
}

@test "vmctl-host refuses unprivileged execution loudly" {
    # The trap this suite was missing: without the root refusal, a privilege
    # failure degrades into empty results with a bare nonzero exit — the
    # exact live failure, invisible to every layer. The suite itself runs
    # unprivileged, so no user-switching machinery is needed: run raw.
    # Status only here: die() speaks on stderr, whose capture is shell-
    # dependent; the message text is pinned statically below.
    unset SSH_ORIGINAL_COMMAND
    unset VMCTL_ALLOW_NONROOT
    export PATH="/usr/bin:/bin"
    run bash "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" list
    [ "$status" -ne 0 ]
    assert_file_contains "$VMCTL_HOST" 'must run as root via the vmctl sudoers entry'
}

@test "the control channel composes: sudo invocation, sudoers grant, env" {
    # The three artifacts must agree or the channel runs unprivileged and
    # every verb fails: ForceCommand invokes through sudo, sudoers grants
    # exactly the wrapper plus the verb channel, in the repo source AND the
    # fallback heredoc (which fires precisely when the source is missing).
    local frag="${PROJECT_ROOT}/provision/host/frag/25-desktop-control.sh"
    assert_file_contains "$frag" 'command="sudo /usr/local/sbin/vmctl-host"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/sudoers" \
        'vmctl ALL=(root) NOPASSWD: /usr/local/sbin/vmctl-host'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/sudoers" \
        'env_keep += "SSH_ORIGINAL_COMMAND"'
    assert_file_contains "$frag" 'env_keep += "SSH_ORIGINAL_COMMAND"'
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
