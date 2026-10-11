#!/usr/bin/env bats
# tests/static/invariants.bats — check repo-wide invariants

load '../lib/helpers'

# Covers: R-05.1.1, I-05.1, R-09.2.5
@test "no hardcoded popiel outside personalization.sh" {
    local result
    result=$(grep -r 'popiel' --include='*.sh' --include='*.toml' --include='*.conf' \
        --include='*.yml' --include='*.yaml' "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v '/tests/' \
        | grep -v '.git/' \
        | grep -v '/output/' \
        | grep -v 'popiel/nested_dev' || true)
    [ -z "$result" ]
}

# Covers: R-05.1.1, I-05.1, R-09.2.5
@test "no hardcoded tapopiel@gmail.com outside personalization.sh" {
    local result
    result=$(grep -r 'tapopiel@gmail.com' --include='*.sh' --include='*.toml' \
        "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v '/tests/' \
        | grep -v '.git/' \
        | grep -v '/output/' || true)
    [ -z "$result" ]
}

# Covers: R-05.1.1, I-05.1, R-01.4.1
@test "no hardcoded target disk outside personalization.sh" {
    # The answer file is built on one machine and installed on another, so a
    # literal device name in live config means someone hardcoded a guess about
    # the target hardware. The one legitimate home for it is
    # PERSONALIZATION_TARGET_DISKS, which the user edits deliberately.
    # Comment lines are excluded: they carry format examples, not selections.
    local result
    result=$(grep -rnE '"(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)"' \
        --include='*.sh' --include='*.toml' "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v 'tests/' \
        | grep -v '.git/' \
        | grep -v '/output/' \
        | grep -vE ':[[:space:]]*#' || true)
    [ -z "$result" ]
}

# Covers: R-01.4.1, R-01.4.2, A-01.5
@test "answer-host.toml carries no literal disk-list fallback" {
    # A literal here would be used verbatim by the installer and could point the
    # install at the wrong physical disk. -F and exact comparison throughout,
    # because a bare '[' is not a valid regex and grep's error status would make
    # a plain `grep -q` pass vacuously.
    local answer="${PROJECT_ROOT}/provision/host/answer-host.toml"

    # Exactly one disk-list key, so no second/override line can sneak in.
    run grep -c -F 'disk-list' "$answer"
    [ "$output" = "1" ]

    # ...and that line is the placeholder the build substitutes, with the array
    # contents (not a quoted string) so a multi-entry list renders correctly.
    run grep -x -F 'disk-list = [__TARGET_DISKS__]' "$answer"
    [ "$status" -eq 0 ]
    [ "$output" = 'disk-list = [__TARGET_DISKS__]' ]
}

# Covers: R-03.7.2, R-04.9.1, R-09.2.6
@test "frag/30 contains OS disk sizes from decision table" {
    # The substance is the size, so assert the size against whatever storage id
    # the fragment uses. Naming the storage here would re-couple this test to
    # the storage variable, and the variable exists so the preflight and the
    # guests cannot disagree about it. Bare `storage:size` is the canonical
    # creation form; the redundant `,size=XG` suffix was dropped when PVE 9
    # started rejecting unvalidated option shapes.
    assert_file_matches "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" \
        '^\s*--scsi0 \$\{GUEST_STORAGE\}:40[[:space:]]'
    assert_file_matches "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" \
        '^\s*--scsi0 \$\{GUEST_STORAGE\}:80[[:space:]]'
}

# Covers: R-09.2.6
@test "frag/30 contains RAM/core sizes from decision table" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DESKTOP_MEM=8192'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'LLM_MEM=16384'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DEV_MEM=8192'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DESKTOP_CORES=4'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'LLM_CORES=6'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DEV_CORES=4'
}

# Covers: R-02.2.7
@test "evdev toggle propagates because only the keyboard grabs all" {
    # QEMU's group propagation skips every object carrying grab_all, so a
    # mouse object with grab_all never follows the toggle (observed live:
    # keyboard flipped, mouse stayed grabbed). grab_all belongs on the
    # toggle-owning keyboard alone; the mouse follows with defaults.
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" \
        'id=rkbd,evdev=${RACK_KBD_EVIDEV},grab_all=on'
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" \
        'id=rmouse,evdev=${RACK_MOUSE_EVIDEV},grab_all'
}

# Covers: R-05.6.1, R-06.2.1, R-09.2.7, A-05.3
@test "user-data templates contain required placeholders" {
    # Every token frag/30 substitutes. A guest seed that reaches the installer
    # with a surviving token boots without its login hash, its operator key or
    # its desktop fleet-control key — frag/30 aborts on this, and so does the
    # pre-commit hook, but the templates are the contract being asserted here.
    # All guests carry the shared identity set; only the desktop carries the
    # Filbert operator key (two-key trust model).
    local token
    for token in \
        '__PERSONALIZATION_USERNAME__' \
        '__PERSONALIZATION_FULLNAME__' \
        '__PERSONALIZATION_UID__' \
        '__PERSONALIZATION_GID__' \
        '__GUEST_ID_PUBKEY__' \
        'CHANGE_ME_HASHED' \
    ; do
        for ud in desktop llm dev; do
            assert_file_contains "${PROJECT_ROOT}/${ud}/user-data/user-data" "$token"
        done
    done
    assert_file_contains "${PROJECT_ROOT}/desktop/user-data/user-data" '__ADMIN_PUBKEY__'
}

# Covers: R-06.2.3, I-06.2, A-06.5
@test "the desktop seed carries both desktop private-key placeholders" {
    # devctl is unusable on the desktop without these two: pvehost_vmctl is
    # the restricted fleet-control credential and nested-dev-id is the guest
    # identity key. The other two guests must not receive a private half.
    local token
    for token in '__VMCTL_PRIV_B64__' '__GUEST_ID_PRIV_B64__'; do
        assert_file_contains "${PROJECT_ROOT}/desktop/user-data/user-data" "$token"
    done
    for ud in llm dev; do
        run grep -E '__[A-Z_]*PRIV_B64__' "${PROJECT_ROOT}/${ud}/user-data/user-data"
        [ -z "$output" ]
    done
}

# Covers: R-01.12.2, R-09.2.7
@test "host templates carry the placeholders their renderer substitutes" {
    # Each entry is "file|placeholder". A missing placeholder does not fail the
    # build; it ships an unsubstituted token into the answer file or the host
    # bootstrap, where it surfaces as a broken install.
    local entry file placeholder
    for entry in \
        "provision/host/answer-host.toml|__GITHUB_REF__" \
        "provision/host/answer-host.toml|__ROOT_SSH_KEY__" \
        "provision/host/answer-host.toml|__ROOT_PASSWORD_HASH__" \
        "provision/host/answer-host.toml|__TARGET_DISKS__" \
        "provision/host/first-boot.sh|__PERSONALIZATION_PASSWORD_HASH__" \
        "provision/host/first-boot.sh|__PERSONALIZATION_UID__" \
        "provision/host/first-boot.sh|__PERSONALIZATION_GID__" \
        "provision/host/first-boot.sh|__PERSONALIZATION_HOME__" \
        "provision/host/first-boot.sh|__ADMIN_PUBKEY__" \
    ; do
        file="${entry%%|*}"
        placeholder="${entry##*|}"
        assert_file_contains "${PROJECT_ROOT}/${file}" "$placeholder"
    done
}

# Covers: R-05.4.3, I-05.2
@test "first-boot.sh carries no root password hash" {
    # The bootstrap persists its hash to disk, so root's credential must not
    # ride along in it — that is the whole point of the two-file split.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '__ROOT_PASSWORD_HASH__'
}

# Covers: R-05.6.3, I-05.3, A-05.14
@test "no committed host template carries a real password hash" {
    # Both hashes are gitignored secrets read at build time. A hash in a
    # template would be published to GitHub and shipped in every built ISO.
    for f in provision/host/first-boot.sh provision/host/answer-host.toml \
             provision/host/build-iso.sh; do
        run grep -E '\$[0-9yab]\$' "${PROJECT_ROOT}/${f}"
        [ -z "$output" ]
    done
}

# Covers: I-05.4, R-09.5.2, A-05.14
@test "neither password hash is tracked by git" {
    for f in keys/personalization-password-hash keys/root-password-hash; do
        run git -C "$PROJECT_ROOT" ls-files --error-unmatch "$f"
        [ "$status" -ne 0 ]
    done
}

# Covers: R-09.5.3
@test "the stale password-hash names are referenced nowhere in the source tree" {
    # Both files were renamed: keys/password-hash ->
    # keys/personalization-password-hash, and /root/.password-hash ->
    # /root/.personalization-password-hash. A leftover reference in the source
    # tree reads as a missing file at build time, or worse as a second,
    # differently-named secret.
    #
    # Scoped to the source tree and the operator docs: the negative assertions
    # below necessarily name the old paths, and specs/09 quotes them in
    # documenting the rename.
    local result
    for dir in provision desktop llm dev; do
        result=$(grep -rn 'keys/password-hash\|/root/\.password-hash' \
            --exclude='*.swp' "${PROJECT_ROOT}/${dir}" 2>/dev/null || true)
        [ -z "$result" ]
    done
    for doc in BUILDING.md README.md; do
        [ ! -f "${PROJECT_ROOT}/${doc}" ] && continue
        result=$(grep -n 'keys/password-hash\|/root/\.password-hash' \
            "${PROJECT_ROOT}/${doc}" 2>/dev/null || true)
        [ -z "$result" ]
    done
}

# Covers: R-06.2.1
@test "frag/30 sources personalization.sh from correct path" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" '/root/provision/personalization.sh'
}

# Covers: R-05.1.4, A-05.4, A-06.3
@test "frag/30 aborts when personalization vars are empty" {
    # The specific guard, not a bare `exit 1` somewhere in a 400-line script:
    # this is the check that stops the host boot with an operator-readable
    # reason instead of creating guests with a blank username or a default UID.
    # It covers UID and GID as well as name, because an unset UID would let the
    # seed ship a guest account whose identity no longer matches the host's.
    local frag30="${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    local var
    for var in PERSONALIZATION_USERNAME PERSONALIZATION_FULLNAME \
               PERSONALIZATION_UID PERSONALIZATION_GID; do
        assert_file_contains "$frag30" "$var"
    done
    assert_file_contains "$frag30" 'not set — check ${ROOT}/root/provision/personalization.sh'
    assert_file_contains "$frag30" \
        'Personalization password hash not found: ${PERSONALIZATION_HASH_FILE}'
}

# Covers: R-03.7.2
@test "data volume size is 500 GB" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DATA_VOL_SIZE=500'
}

# --- Guest egress policy (Spec 00 R-00.2.6) ---
# The FORWARD chain is the only thing that gives a guest a route off vmbr0.
# A policy stated in a comment but not backed by a rule is the failure mode
# these guard: the desktop was documented as unrestricted with no rule at all,
# so the bastion had no egress.

# Covers: R-00.2.6, R-01.10.2, R-09.2.8
@test "the desktop has an unrestricted egress rule toward the LAN NIC" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
        '-o "$PHYS_NIC" -s 192.168.100.100 -j ACCEPT'
    assert_file_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '-o CHANGE_ME_DETECT_AT_PROVISION -s 192.168.100.100 -j ACCEPT'
}

# Covers: R-00.2.6, R-09.2.8
@test "the LLM VM and the whole dev range are granted egress" {
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    # Uniform egress for 101-249: the loop must cover the LLM VM plus every
    # dev VM (template + all clones). A fourth exception outside the range
    # would silently give it a route off vmbr0.
    assert_file_contains "$frag" 'seq 101 249'
    for port in 53 80 443; do
        assert_file_contains "$frag" "--dport ${port} -j ACCEPT"
    done
}

# Covers: R-00.2.6
@test "guest DNS egress allows TCP as well as UDP" {
    # A truncated or oversized DNS answer falls back to TCP. UDP-only DNS fails
    # exactly when the guest most needs an answer, and the host's own OUTPUT
    # chain already allows both.
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-p udp --dport 53 -j ACCEPT'
    assert_file_contains "$frag" '-p tcp --dport 53 -j ACCEPT'
}

# Covers: R-00.2.2, R-01.9.1
@test "the host admits guest DHCP and DNS on vmbr0, both directions" {
    # dnsmasq serves DHCP and DNS to the private bridge, and a service the
    # firewall blocks does not exist: without these rules every guest installer
    # stalls before writing a byte. Scoped to vmbr0 (no physical ports), so
    # this reaches guests and nothing else — the LAN side stays closed.
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-i vmbr0 -p udp --dport 67 -j ACCEPT'
    assert_file_contains "$frag" '-i vmbr0 -p udp --dport 53 -j ACCEPT'
    assert_file_contains "$frag" '-i vmbr0 -p tcp --dport 53 -j ACCEPT'
    assert_file_contains "$frag" '-o vmbr0 -p udp --sport 67 --dport 68 -j ACCEPT'
    assert_file_contains "$frag" '-o vmbr0 -p udp --sport 53 -j ACCEPT'
    assert_file_contains "$frag" '-o vmbr0 -p tcp --sport 53 -j ACCEPT'
}

# Covers: R-01.10.2, R-01.10.4
@test "DNAT'd LAN traffic to the desktop passes the filter" {
    # PREROUTING rewrites these destinations, but rewritten packets still
    # traverse FORWARD: without explicit accepts the documented SSH/VNC
    # access is translated and then silently dropped.
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-o vmbr0 -p tcp -d 192.168.100.100 --dport 22 -j ACCEPT'
    assert_file_contains "$frag" '-o vmbr0 -p tcp -d 192.168.100.100 --dport 5900 -j ACCEPT'
}

# Covers: R-02.2.1
@test "no RDP path remains anywhere in the firewall" {
    # RDP is eliminated, not merely unforwarded: a 3389 rule in either the
    # fragment or the reference would reopen a port the guest no longer
    # serves and the spec no longer documents.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
        '3389'
    assert_file_not_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '3389'
}

# Covers: R-01.10.2, A-01.15
@test "only the desktop may initiate inter-VM traffic" {
    # A-01.15 binds every guest but the desktop: the single vmbr0→vmbr0
    # ACCEPT must be desktop-sourced, and no other bridge-to-bridge ACCEPT
    # may exist — with FORWARD default DROP, anything else admitted here is
    # a guest-to-guest path. Checked in both the fragment applying the live
    # state and the reference the boot restore uses, so the two cannot drift.
    local file count
    for file in "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
                "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"; do
        assert_file_contains "$file" \
            '-i vmbr0 -o vmbr0 -s 192.168.100.100 -j ACCEPT'
        count="$(grep -cE -- '-i vmbr0 -o vmbr0.*-j ACCEPT' "$file")"
        [ "$count" -eq 1 ] || {
            echo "$file: expected exactly one vmbr0->vmbr0 ACCEPT (the desktop's), found $count" >&2
            return 1
        }
    done
}

# Covers: R-00.2.6
@test "uniform dev egress covers the whole 101-249 range" {
    # All dev VMs (plus the LLM VM) share one egress policy. The reference
    # grants the subnet; the fragment expands it per-IP at provision time.
    # Neither may single out .104 as denied: uniform access is the policy.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
        'other dev VMs denied'
    assert_file_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '-s 192.168.100.0/24 -p udp --dport 53 -j ACCEPT'
}

# Covers: R-00.2.6, R-09.2.8
@test "the reference ruleset grants each allowed guest each allowed port" {
    # The reference file documents the live policy. If the two drift, a
    # reviewer reading the reference is reading a policy the host does not
    # enforce. The reference grants the uniform subnet rule; the fragment
    # expands the same policy per-IP. Compare the rules, not the comments.
    local conf="${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"
    for port in "udp --dport 53" "tcp --dport 53" "tcp --dport 80" "tcp --dport 443"; do
        grep -qE -- "-s 192.168.100.0/24 -p ${port} -j ACCEPT" "$conf" || {
            echo "reference ruleset is missing: subnet ${port}" >&2
            return 1
        }
    done
}

# Covers: R-00.2.5, R-01.10.2
@test "host OUTPUT allows HTTP alongside HTTPS/DNS/NTP with rate-limited ICMP" {
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-A OUTPUT -p tcp --dport 80 -j ACCEPT'
    assert_file_contains "$frag" '-A OUTPUT -p tcp --dport 443 -j ACCEPT'
    assert_file_contains "$frag" '-m limit --limit 10/second -j ACCEPT'
    assert_file_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '-A OUTPUT -p tcp --dport 80 -j ACCEPT'
}

# Covers: R-02.1.7
@test "the LLM guest hostname is lychee-llm everywhere" {
    assert_file_contains "${PROJECT_ROOT}/llm/user-data/user-data" 'hostname: lychee-llm'
    assert_file_contains "${PROJECT_ROOT}/llm/llm-firstboot.sh" 'hostnamectl set-hostname lychee-llm'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" 'HOST=lychee-llm'
}

# Covers: R-00.8.3, R-05.8.7
@test "frag/30 records the resolved SHA for future rebuilds" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" \
        'etc/nested-dev/ref-sha'
}

# Covers: R-05.2.4
@test "the host account trusts both the Filbert and desktop keys" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/25-desktop-control.sh" \
        'Host account now trusts both keys'
}

# Covers: R-00.5.1, R-06.1.4, I-06.4
@test "no prebuilt guest image is vendored into the repository" {
    # Every guest installs from official media with a host-assembled seed; a
    # tracked qcow2/img/iso, a payloads/ directory, or an image-conversion
    # pass (virt-sysprep/zerofree) would be a second, unaudited install path.
    local found
    found="$(git -C "$PROJECT_ROOT" ls-files | grep -iE '\.(qcow2|img|iso)$' || true)"
    [ -z "$found" ] || { echo "vendored image blobs tracked:" >&2; echo "$found" >&2; return 1; }
    [ ! -d "${PROJECT_ROOT}/payloads" ] || { echo "payloads/ directory exists" >&2; return 1; }
    found="$(grep -rliE 'virt-sysprep|zerofree' "${PROJECT_ROOT}/provision" "${PROJECT_ROOT}/desktop" "${PROJECT_ROOT}/llm" "${PROJECT_ROOT}/dev" 2>/dev/null || true)"
    [ -z "$found" ] || { echo "image-conversion tooling referenced:" >&2; echo "$found" >&2; return 1; }
}

# Covers: R-08.7.5, A-08.18
@test "build output lives outside version control" {
    # Only the directory placeholder may be tracked; ISOs, manifests and work
    # files must never be committed.
    run git -C "$PROJECT_ROOT" check-ignore output/MANIFEST
    [ "$status" -eq 0 ]
    local tracked
    tracked="$(git -C "$PROJECT_ROOT" ls-files output | grep -v -xF 'output/.gitkeep' || true)"
    [ -z "$tracked" ] || { echo "tracked build output:" >&2; echo "$tracked" >&2; return 1; }
}

# Covers: R-05.8.1
@test "the release reference is assigned in exactly one place" {
    # Fallback reads (${VAR:-default}) and placeholder rewrites are not
    # assignments; a second quoted assignment would be a second source of
    # truth for what the fleet builds from.
    local found
    found="$(grep -rnE 'PERSONALIZATION_(REF|REPO)="' "${PROJECT_ROOT}/provision" "${PROJECT_ROOT}/desktop" "${PROJECT_ROOT}/llm" "${PROJECT_ROOT}/dev" 2>/dev/null | grep -v 'provision/personalization.sh' || true)"
    [ -z "$found" ] || { echo "second ref/repo assignment:" >&2; echo "$found" >&2; return 1; }
    assert_file_contains "${PROJECT_ROOT}/provision/personalization.sh" 'PERSONALIZATION_REF="'
    assert_file_contains "${PROJECT_ROOT}/provision/personalization.sh" 'PERSONALIZATION_REPO="'
}

# Covers: R-05.1.1, I-05.1, A-05.2
@test "the configured full name appears only in personalization.sh" {
    # The username and email have sibling tests above; the full name rides in
    # GECOS and mail headers, so a literal copy elsewhere is a second identity
    # literal with the same blast radius.
    local fullname found
    fullname="$(grep -E '^PERSONALIZATION_FULLNAME=' "${PROJECT_ROOT}/provision/personalization.sh" | cut -d'"' -f2)"
    [ -n "$fullname" ] || { echo "PERSONALIZATION_FULLNAME not found" >&2; return 1; }
    found="$(grep -rF "$fullname" --include='*.sh' --include='*.toml' --include='*.conf' \
        --include='user-data' "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v '/tests/' \
        | grep -v '.git/' \
        | grep -v '/output/' || true)"
    [ -z "$found" ] || { echo "full-name literal outside personalization.sh:" >&2; echo "$found" >&2; return 1; }
}

# Covers: R-07.9.1
@test "the dev range holds 147 IDs" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" 'DEV_MIN=103'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" 'DEV_MAX=249'
    [ "$((249 - 103 + 1))" -eq 147 ]
}

# Covers: R-07.4.4, A-07.15
@test "a clone's MAC embeds its VM ID" {
    # Uniqueness by construction: the fixed prefix plus a suffix derived from
    # the allocated ID, so two clones cannot share a link address.
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" 'MAC="52:54:00:00:02:${MAC_SUFFIX}"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/vmctl/vmctl-host" 'NEXT_VID & 255'
}

# Covers: R-07.2.6, A-07.4
@test "a missing control program fails naming the program" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/25-desktop-control.sh" \
        'vmctl-host source not found'
}

# Covers: R-05.3.2, R-05.3.3, A-05.10
@test "host account creation reconciles and refuses a taken UID" {
    # Re-running is a no-op reconcile, not a second account; a UID/GID held
    # by another account aborts instead of shadowing it.
    assert_file_contains "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        'account exists — reconciling'
    assert_file_contains "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        'refusing to create a second identity'
}

# Covers: R-07.6.1, A-07.19
@test "the host-root pin matches the desktop lease" {
    # The trust entry pins the desktop key with from="<desktop-IP>"; the lease
    # assigns that IP to the desktop. If either changes alone, access silently
    # fails while the key is still present — so the two must agree, checked
    # in every source that states the desktop address.
    local pin_ip lease_ref lease_frag
    pin_ip="$(grep -E '^DESKTOP_IP=' "${PROJECT_ROOT}/provision/host/frag/25-desktop-control.sh" | cut -d'"' -f2)"
    [ -n "$pin_ip" ] || { echo "DESKTOP_IP not found in frag/25" >&2; return 1; }
    lease_ref="$(grep -E '^dhcp-host=[^,]*,lychee,' "${PROJECT_ROOT}/provision/network/dnsmasq.conf" | rev | cut -d, -f1 | rev)"
    lease_frag="$(grep -E 'dhcp-host=[^,]*,lychee,' "${PROJECT_ROOT}/provision/host/frag/28-network.sh" | head -1 | rev | cut -d, -f1 | rev)"
    [ -n "$lease_ref" ] || { echo "desktop lease not found in dnsmasq.conf" >&2; return 1; }
    [ -n "$lease_frag" ] || { echo "desktop lease not found in frag/28" >&2; return 1; }
    [ "$pin_ip" = "$lease_ref" ] || { echo "pin $pin_ip != reference lease $lease_ref" >&2; return 1; }
    [ "$pin_ip" = "$lease_frag" ] || { echo "pin $pin_ip != frag/28 lease $lease_frag" >&2; return 1; }
    [ "$pin_ip" = "192.168.100.100" ] || { echo "desktop address moved to $pin_ip" >&2; return 1; }
}

# Covers: R-05.6.3, A-05.17
@test "the pre-commit hook blocks real password hashes in seeds" {
    assert_file_contains "${PROJECT_ROOT}/.githooks/pre-commit" 'password: "[^C]'
    assert_file_contains "${PROJECT_ROOT}/.githooks/pre-commit" 'CHANGE_ME_HASHED'
}

# Covers: R-08.1.1, R-08.1.2, R-08.1.3, R-08.1.4
@test "the builder image is a lean same-release toolchain" {
    local df="${PROJECT_ROOT}/dev/docker/Dockerfile.nested"
    assert_file_contains "$df" 'FROM ubuntu:26.04'
    local tool
    for tool in wget xorriso libarchive-tools whois git curl gnupg python3; do
        assert_file_contains "$df" "$tool"
    done
    assert_file_contains "$df" 'rm -rf /var/lib/apt/lists'
    assert_file_not_contains "$df" 'xrdp'
    run grep -iE 'nvidia|cuda|ollama|gnome|x11vnc|firefox' "$df"
    [ -z "$output" ]
}
