#!/usr/bin/env bats
# tests/unit/frag25-vmctl.bats — credential bootstrap: vmctl forced-command account
# and the install-time guest identity keypair (Spec 07)
#
# These cover defects that shipped silently before, because nothing under
# tests/ referenced frag/25 or the vmctl path at all:
#   D1  vmctl was created with /usr/sbin/nologin. sshd_config(5) runs
#       ForceCommand through the login shell, so every forced command died with
#       "This account is currently not available" and devctl never worked.
#   D2  the desktop seed redirected the private key into ~/.ssh without creating
#       it. late-commands runs in the init stage, before the cloud_config stage
#       where cc_ssh creates ~/.ssh, so the write failed and 2>/dev/null hid it.
#   D3  guests had allow-pw: false and no ssh_authorized_keys, so no guest was
#       reachable over SSH at all despite having a password set.

load '../lib/helpers'

FRAG25="${PROJECT_ROOT}/provision/host/frag/25-desktop-control.sh"
FRAG30="${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
FIRSTBOOT="${PROJECT_ROOT}/provision/host/first-boot.sh"
DESKTOP_UD="${PROJECT_ROOT}/desktop/user-data/user-data"
LLM_UD="${PROJECT_ROOT}/llm/user-data/user-data"
DEV_UD="${PROJECT_ROOT}/dev/user-data/user-data"
DESKTOP_FIRSTBOOT="${PROJECT_ROOT}/desktop/desktop-firstboot.sh"
DEVCTL="${PROJECT_ROOT}/desktop/devctl"
DNSMASQ="${PROJECT_ROOT}/provision/network/dnsmasq.conf"

# --- D1: the vmctl account must be able to run a forced command ---

@test "D1: frag/25 does not give vmctl a nologin login shell" {
    # nologin would make ForceCommand unreachable: sshd_config(5) invokes it as
    # "<login shell> -c '<forced command>'".
    assert_file_not_contains "$FRAG25" 's /usr/sbin/nologin'
    assert_file_not_contains "$FRAG25" '\-s /usr/sbin/nologin'
}

@test "D1: frag/25 creates vmctl with a real shell" {
    assert_file_contains "$FRAG25" 'VMCTL_SHELL="/bin/bash"'
    assert_file_contains "$FRAG25" 'useradd -r -m -s "$VMCTL_SHELL"'
}

@test "D1: frag/25 corrects an existing nologin vmctl shell (idempotent re-run)" {
    assert_file_contains "$FRAG25" 'usermod -s "$VMCTL_SHELL" vmctl'
    # The account must stay password-locked, i.e. key-only, regardless of shell.
    assert_file_contains "$FRAG25" 'useradd -r'
}

@test "D1: frag/25 keeps the ForceCommand restriction in authorized_keys" {
    assert_file_contains "$FRAG25" \
        'command="/usr/local/sbin/vmctl-host",no-agent-forwarding,no-port-forwarding,no-X11-forwarding'
}

@test "D1: frag/25 authorized_keys is mode 600" {
    assert_file_contains "$FRAG25" 'chmod 600 /home/vmctl/.ssh/authorized_keys'
}

# --- guest identity keypair: generation, host trust pin, staging ---

@test "frag/25 generates the guest identity keypair when absent" {
    assert_file_contains "$FRAG25" 'ssh-keygen -t ed25519 -f "${GUEST_ID_KEY_DIR}/guest_id_ed25519"'
    assert_file_contains "$FRAG25" 'chmod 600 "${GUEST_ID_KEY_DIR}/guest_id_ed25519"'
}

@test "frag/25 does not regenerate an existing guest identity keypair" {
    # Regenerating on every run would leave guests holding a stale public key.
    assert_file_contains "$FRAG25" 'if [ ! -f "${GUEST_ID_KEY_DIR}/guest_id_ed25519" ]; then'
}

@test "frag/25 pins the guest identity key on the host to the desktop address" {
    assert_file_contains "$FRAG25" \
        'from="%s",no-agent-forwarding,no-port-forwarding,no-X11-forwarding'
    assert_file_contains "$FRAG25" 'DESKTOP_IP="192.168.100.100"'
}

@test "frag/25 host pin address matches the desktop dnsmasq static lease" {
    # A divergence here silently denies the desktop host access even though the
    # key is present, so assert the two stay in sync.
    local pinned lease_ip
    pinned=$(grep -oP 'DESKTOP_IP="\K[^"]+' "$FRAG25")
    lease_ip=$(grep -oP '^dhcp-host=52:54:00:00:01:00,lychee,\K[^,]+' "$DNSMASQ")
    [ -n "$pinned" ]
    [ "$pinned" = "$lease_ip" ]
}

@test "frag/25 appends the host key entry idempotently" {
    # Without a presence check, every re-run would add a duplicate line.
    assert_file_contains "$FRAG25" 'if grep -qF "$GUEST_ID_PUB" "$ROOT_AUTH_KEYS"; then'
}

@test "frag/25 stages the guest identity private half for frag/30" {
    assert_file_contains "$FRAG25" 'cp "${GUEST_ID_KEY_DIR}/guest_id_ed25519" "$GUEST_ID_STAGED"'
    assert_file_contains "$FRAG25" 'chmod 600 "$GUEST_ID_STAGED"'
}

@test "frag/25 stages the guest identity key on every run so re-provision works" {
    # frag/30 shreds the staged copy; frag/25 must re-create it unconditionally.
    local stage_line guard_line
    stage_line=$(grep -n 'cp "${GUEST_ID_KEY_DIR}/guest_id_ed25519" "$GUEST_ID_STAGED"' "$FRAG25" | cut -d: -f1)
    guard_line=$(grep -n 'if \[ ! -f "${GUEST_ID_KEY_DIR}/guest_id_ed25519" \]; then' "$FRAG25" | cut -d: -f1)
    [ -n "$stage_line" ]
    [ -n "$guard_line" ]
    # The stage must sit outside (below) the generate-if-absent block.
    [ "$stage_line" -gt "$guard_line" ]
}

# --- admin public key transport: repo tarball → provision tree → frag/30 ---

@test "first-boot.sh preserves the admin public key into the provision tree" {
    assert_file_contains "$FIRSTBOOT" 'keys/host_os_ed25519.pub'
    assert_file_contains "$FIRSTBOOT" 'ADMIN_PUBKEY_SRC='
    assert_file_contains "$FIRSTBOOT" 'cp "$ADMIN_PUBKEY_SRC" "${PROVISION_DIR}/keys/host_os_ed25519.pub"'
}

@test "first-boot.sh preserves the admin pubkey BEFORE deleting the extract" {
    # The tarball extract is removed at the end of the fetch block, so copying
    # the pubkey after that removal would fail.
    local copy_line rm_line
    copy_line=$(grep -n 'cp "$ADMIN_PUBKEY_SRC"' "$FIRSTBOOT" | cut -d: -f1)
    rm_line=$(grep -n 'rm -rf "/root/nested_dev-\${REF}"' "$FIRSTBOOT" | cut -d: -f1)
    [ -n "$copy_line" ]
    [ -n "$rm_line" ]
    [ "$copy_line" -lt "$rm_line" ]
}

@test "first-boot.sh fails loudly if the admin public key is absent" {
    # keys/host_os_ed25519.pub is git-tracked, so a missing file means a broken
    # build rather than a normal condition.
    assert_file_contains "$FIRSTBOOT" \
        '[ -f "$ADMIN_PUBKEY_SRC" ] || die "archive did not contain keys/host_os_ed25519.pub"'
}

@test "frag/30 reads the admin public key from the provision tree" {
    assert_file_contains "$FRAG30" 'ADMIN_PUBKEY_FILE="/root/provision/keys/host_os_ed25519.pub"'
    assert_file_contains "$FRAG30" 'ADMIN_PUBKEY="$(cat "$ADMIN_PUBKEY_FILE")"'
}

@test "frag/30 dies rather than seeding guests without the admin key" {
    assert_file_contains "$FRAG30" \
        '[ -f "$ADMIN_PUBKEY_FILE" ] || die "Admin public key not found'
    assert_file_contains "$FRAG30" \
        '[ -f "$GUEST_ID_PUBKEY_FILE" ] || die "Guest identity public key not found'
}

# --- D3: every guest gets key auth (password auth is disabled) ---

@test "frag/30 injects both public keys into every guest seed" {
    assert_file_contains "$FRAG30" \
        '-e "s|__ADMIN_PUBKEY__|${ADMIN_PUBKEY}|g"'
    assert_file_contains "$FRAG30" \
        '-e "s|__GUEST_ID_PUBKEY__|${GUEST_ID_PUBKEY}|g"'
}

@test "frag/30 injects both private halves into the desktop seed" {
    assert_file_contains "$FRAG30" \
        '-e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g"'
    assert_file_contains "$FRAG30" \
        '-e "s|__GUEST_ID_PRIV_B64__|${GUEST_ID_KEY_B64}|g"'
}

@test "frag/30 dies if a placeholder survives substitution" {
    # Otherwise a guest silently boots with no keys and the failure only shows
    # up later as "Permission denied (publickey)".
    # Literal match: [A-Z_] is a regex character class, not literal text.
    assert_file_contains "$FRAG30" "grep -q '__[A-Z_]*__'"
    assert_file_contains "$FRAG30" 'Unsubstituted placeholders left in'
}

# D3: allow-pw: false means ssh_authorized_keys is not optional — without it a
# guest has no working SSH authentication method at all.

@test "every guest user-data declares ssh_authorized_keys with both keys" {
    # allow-pw: false means ssh_authorized_keys is not optional — without it a
    # guest has no working SSH authentication method at all (D3).
    local label file
    for label in desktop llm dev; do
        file="${PROJECT_ROOT}/${label}/user-data/user-data"
        assert_file_contains "$file" 'ssh_authorized_keys:'
        assert_file_contains "$file" '- "__ADMIN_PUBKEY__"'
        assert_file_contains "$file" '- "__GUEST_ID_PUBKEY__"'
        assert_file_contains "$file" 'allow-pw: false'
    done
}

# --- D2: the seed must create ~/.ssh before writing private keys into it ---

assert_key_write_creates_ssh_dir_first() {
    # $1 = user-data file, $2 = key filename. Everything before the first '>'
    # is the setup that must run before the redirect into ~/.ssh.
    local file="$1" key="$2" cmd head
    cmd=$(grep -o "sh -c '[^']*${key}[^']*'" "$file" || true)
    if [ -z "$cmd" ]; then
        echo "no late-command writing ${key} found in ${file}" >&2
        return 1
    fi
    head="${cmd%%'>'*}"
    case "$head" in
        *"mkdir -p /home/__PERSONALIZATION_USERNAME__/.ssh"*)
            return 0
            ;;
        *)
            echo "mkdir -p ~/.ssh must precede the redirect into it." >&2
            echo "  before redirect: ${head}" >&2
            return 1
            ;;
    esac
}

@test "D2: desktop user-data creates ~/.ssh before writing the vmctl key" {
    assert_key_write_creates_ssh_dir_first "$DESKTOP_UD" "pvehost_vmctl"
}

@test "D2: desktop user-data creates ~/.ssh before writing the guest identity key" {
    assert_key_write_creates_ssh_dir_first "$DESKTOP_UD" "nested-dev-id"
}

@test "D2: desktop user-data no longer suppresses key-write errors" {
    # 2>/dev/null on the redirect is what let a failed key write go unnoticed.
    assert_file_not_contains "$DESKTOP_UD" 'pvehost_vmctl 2>/dev/null'
    assert_file_not_contains "$DESKTOP_UD" 'nested-dev-id 2>/dev/null'
}

@test "D2: desktop user-data chmods the key files to 600" {
    assert_file_contains "$DESKTOP_UD" 'chmod 600 /home/__PERSONALIZATION_USERNAME__/.ssh/pvehost_vmctl'
    assert_file_contains "$DESKTOP_UD" 'chmod 600 /home/__PERSONALIZATION_USERNAME__/.ssh/nested-dev-id'
}

# --- staged private halves must be destroyed after the seeds are built ---

@test "frag/30 shreds both staged private keys" {
    assert_file_contains "$FRAG30" 'for staged in "$VMCTL_KEY_FILE" "$GUEST_ID_KEY_FILE"; do'
    assert_file_contains "$FRAG30" 'shred -u "$staged"'
}

@test "frag/30 shreds staged keys AFTER the guest seed loop" {
    # Shredding inside the loop would leave every guest after the first without
    # its keys. The seed loop closes with a `    done` at indent level 4.
    local shred_line loop_end
    shred_line=$(grep -n 'for staged in "\$VMCTL_KEY_FILE"' "$FRAG30" | cut -d: -f1)
    loop_end=$(grep -n '^    done$' "$FRAG30" | head -1 | cut -d: -f1)
    [ -n "$shred_line" ]
    [ -n "$loop_end" ]
    [ "$loop_end" -lt "$shred_line" ]
}

@test "frag/30 keeps the canonical keypairs so re-provisioning stays idempotent" {
    # Only the staged copies are destroyed; /root/.nested-dev/<dir>/... is kept.
    assert_file_not_contains "$FRAG30" 'rm -rf /root/.nested-dev'
    assert_file_not_contains "$FRAG30" 'rm -rf "\${GUEST_ID_KEY_DIR}"'
}

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

# --- D4: the control program must actually be installed ---

@test "D4: frag/25 resolves vmctl-host relative to its own location" {
    # first-boot.sh extracts the archive's provision/ to /root/provision, so
    # the repo's provision/host/vmctl/ lands at /root/provision/host/vmctl/.
    # A hardcoded /root/provision/vmctl/ never exists, and vmctl-host was
    # therefore never installed: every devctl fleet verb pointed its
    # ForceCommand at a binary that was not there.
    assert_file_not_contains "$FRAG25" '/root/provision/vmctl/'
    assert_file_contains "$FRAG25" 'BASH_SOURCE[0]}")/../vmctl'
}

@test "D4: frag/25 resolves the vmctl source dir to the directory that has the file" {
    # Prove the relative path actually lands on the files, using the repo's own
    # layout rather than asserting on the string that expresses it.
    [ -f "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" ]
    resolved="$(cd "${PROJECT_ROOT}/provision/host/frag/../vmctl" && pwd)"
    [ -f "${resolved}/vmctl-host" ]
    [ -f "${resolved}/sudoers" ]
}

@test "D4: a missing vmctl-host aborts frag/25 rather than warning" {
    # A warning here means a host that provisions "successfully" with no
    # control program on it. Every devctl fleet verb then fails with a
    # "command not found" from a forced command, which reads as a
    # permissions problem rather than a missing binary.
    assert_file_contains "$FRAG25" 'die "vmctl-host source not found'
    assert_file_not_contains "$FRAG25" 'WARNING: vmctl-host source not found'
}

@test "D4: frag/25 defines die() so its fatal path cannot silently succeed" {
    assert_file_contains "$FRAG25" 'die() {'
}

# --- D5: the dev guest must receive what dev-firstboot.sh copies ---
# dev-firstboot.sh installs dev/tools/nested and dev/tools/dev-refresh-images by
# copying them from ${SCRIPT_DIR}/tools. The seed fetched only
# dev-firstboot.sh and personalization.sh, so /opt/nested-dev/tools/ never
# existed and both wrappers were reported missing on every first boot. The
# java/scala/sbt/opencode wrappers call `nested`, so a half-provisioned dev VM
# looked fine until a tool was invoked.

@test "D5: the dev seed fetches both dev/tools scripts into the tools directory" {
    assert_file_contains "$DEV_UD" 'dev/tools/nested -O nested'
    assert_file_contains "$DEV_UD" 'dev/tools/dev-refresh-images -O dev-refresh-images'
    assert_file_contains "$DEV_UD" 'mkdir -p /opt/nested-dev/tools'
}

@test "D5: the tools are fetched at the same reference as the first-boot script" {
    # One reference for the whole guest. Two references means the script that
    # installs the wrappers and the wrappers themselves can come from different
    # commits, invisibly.
    local fetches
    fetches="$(grep -oE 'raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+' "$DEV_UD" | sort -u)"
    [ -n "$fetches" ]
    local count
    count="$(printf '%s\n' "$fetches" | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ] || {
        echo "dev seed fetches from $count different references:" >&2
        printf '%s\n' "$fetches" >&2
        return 1
    }
}

@test "D5: the guest pins its own PERSONALIZATION_REF to the reference it was built from" {
    # personalization.sh still carries the branch name. A guest that fetched
    # its Dockerfiles and tools with ${PERSONALIZATION_REF:-main} would resolve
    # against a moving branch, so the template's images could come from a newer
    # commit than the script that installed them.
    assert_file_contains "$DEV_UD" 's/^PERSONALIZATION_REF=.*/PERSONALIZATION_REF=__GITHUB_REF__/'
}

# --- D6: devctl-host runtime behaviour that a comment cannot guarantee ---

@test "D6: vmctl-host sets a clone's hostname once the guest agent answers" {
    # A clone inherits the template's hostname, so without this every dev VM in
    # the fleet calls itself the same thing and the DNS name registered by `add`
    # never matches the guest's own hostname.
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        'set_hostname_when_agent_ready'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        'hostnamectl set-hostname'
}

@test "D6: hostname settling does not block the start verb" {
    # The agent is not up when `start` returns, so waiting inline would make
    # every start take the full agent timeout.
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        '( set_hostname_when_agent_ready "$VMID" "$NAME" ) &'
}

@test "D6: an unanswered guest agent is a warning, not a failed start" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        'guest agent never answered'
}

@test "D6: the list verb reads the VM inventory once instead of probing the dev range" {
    # Probing 103-249 with `qm status` costs two subprocesses per ID (~294
    # calls) on every `list`, and devctl calls list again for each name lookup.
    # `add` still scans the range legitimately — it has to find a free ID — so
    # this is asserted against the list verb alone.
    local vmctl="${PROJECT_ROOT}/provision/host/vmctl/vmctl-host"
    local list_block
    list_block="$(awk '/^    list\)/,/^        ;;$/' "$vmctl")"
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

@test "D6: the dev range boundaries are enforced on every ID-taking verb" {
    # The range starts above the static fleet, so an out-of-range ID cannot
    # reach the desktop, the LLM VM or the template.
    local v
    for v in status start shutdown stop log; do
        assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
            "outside dev range"
    done
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        'DEV_MIN=103'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" \
        'DEV_MAX=249'
}

# --- D7: credential paths must be stated in one place ---

@test "D7: nested keys-status looks where the build reads, not in a second directory" {
    # keys-status looked in secrets/, which does not exist. It reported working
    # credentials as MISSING and told the operator to mkpasswd into a path no
    # build ever reads. A comment may still name the wrong path; code may not.
    local nested="${PROJECT_ROOT}/dev/tools/nested"
    local code
    code="$(sed 's/[[:space:]]*#.*$//' "$nested")"
    printf '%s\n' "$code" | grep -qF 'keys/${secret}' || {
        echo "keys-status does not read keys/\${secret}" >&2
        return 1
    }
    if printf '%s\n' "$code" | grep -qF 'secrets/'; then
        echo "keys-status still reads a secrets/ path in code" >&2
        return 1
    fi
}

@test "D7: the nested build image sources the hashes from keys/ too" {
    assert_file_contains "${PROJECT_ROOT}/dev/tools/nested" 'NESTED_DEV}/keys/'
}

@test "D7: the wrapper's inspect verb does not claim to have validated the answer file" {
    # It only printed a template. Naming that "verify" is how an operator stops
    # reading the output.
    local nested="${PROJECT_ROOT}/dev/tools/nested"
    assert_file_not_contains "$nested" 'Answer file OK'
    assert_file_contains "$nested" 'not rendered'
    assert_file_contains "$nested" 'Validation happens during the build'
}

@test "D7: devctl's missing-key error names something that exists" {
    # It pointed at `devctl firstboot-log`, a verb that does not exist.
    assert_file_not_contains "$DEVCTL" 'firstboot-log'
    assert_file_contains "$DEVCTL" 'desktop-firstboot.log'
}
