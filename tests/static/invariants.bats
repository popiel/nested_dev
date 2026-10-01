#!/usr/bin/env bats
# tests/static/invariants.bats — check repo-wide invariants

load '../lib/helpers'

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

@test "frag/30 contains RAM/core sizes from decision table" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DESKTOP_MEM=8192'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'LLM_MEM=16384'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DEV_MEM=8192'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DESKTOP_CORES=4'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'LLM_CORES=6'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DEV_CORES=4'
}

@test "user-data templates contain required placeholders" {
    # Every token frag/30 substitutes. A guest seed that reaches the installer
    # with a surviving token boots without its login hash, its operator key or
    # its desktop fleet-control key — frag/30 aborts on this, and so does the
    # pre-commit hook, but the templates are the contract being asserted here.
    local token
    for token in \
        '__PERSONALIZATION_USERNAME__' \
        '__PERSONALIZATION_FULLNAME__' \
        '__PERSONALIZATION_UID__' \
        '__PERSONALIZATION_GID__' \
        '__ADMIN_PUBKEY__' \
        '__GUEST_ID_PUBKEY__' \
        'CHANGE_ME_HASHED' \
    ; do
        for ud in desktop llm dev; do
            assert_file_contains "${PROJECT_ROOT}/${ud}/user-data/user-data" "$token"
        done
    done
}

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

@test "first-boot.sh carries no root password hash" {
    # The bootstrap persists its hash to disk, so root's credential must not
    # ride along in it — that is the whole point of the two-file split.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '__ROOT_PASSWORD_HASH__'
}

@test "no committed host template carries a real password hash" {
    # Both hashes are gitignored secrets read at build time. A hash in a
    # template would be published to GitHub and shipped in every built ISO.
    for f in provision/host/first-boot.sh provision/host/answer-host.toml \
             provision/host/build-iso.sh; do
        run grep -E '\$[0-9yab]\$' "${PROJECT_ROOT}/${f}"
        [ -z "$output" ]
    done
}

@test "neither password hash is tracked by git" {
    for f in keys/personalization-password-hash keys/root-password-hash; do
        run git -C "$PROJECT_ROOT" ls-files --error-unmatch "$f"
        [ "$status" -ne 0 ]
    done
}

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

@test "frag/30 sources personalization.sh from correct path" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" '/root/provision/personalization.sh'
}

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

@test "data volume size is 500 GB" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DATA_VOL_SIZE=500'
}

# --- Guest egress policy (Spec 00 R-00.2.6) ---
# The FORWARD chain is the only thing that gives a guest a route off vmbr0.
# A policy stated in a comment but not backed by a rule is the failure mode
# these guard: the desktop was documented as unrestricted with no rule at all,
# so the bastion had no egress.

@test "the desktop has an unrestricted egress rule toward the LAN NIC" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
        '-o "$PHYS_NIC" -s 192.168.100.100 -j ACCEPT'
    assert_file_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '-o CHANGE_ME_DETECT_AT_PROVISION -s 192.168.100.100 -j ACCEPT'
}

@test "the LLM VM, the template and the trusted builder are granted egress" {
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    # The egress loop must name exactly the three addresses the policy allows:
    # the LLM VM, the dev template (which builds the toolchain its clones run),
    # and the trusted ISO builder. Adding a fourth here silently gives it a
    # route off vmbr0.
    assert_file_contains "$frag" 'for EGRESS_IP in 192.168.100.101 192.168.100.102 192.168.100.103; do'
    for port in 53 80 443; do
        assert_file_contains "$frag" "--dport ${port} -j ACCEPT"
    done
}

@test "guest DNS egress allows TCP as well as UDP" {
    # A truncated or oversized DNS answer falls back to TCP. UDP-only DNS fails
    # exactly when the guest most needs an answer, and the host's own OUTPUT
    # chain already allows both.
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-p udp --dport 53 -j ACCEPT'
    assert_file_contains "$frag" '-p tcp --dport 53 -j ACCEPT'
}

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

@test "DNAT'd LAN traffic to the desktop passes the filter" {
    # PREROUTING rewrites these destinations, but rewritten packets still
    # traverse FORWARD: without explicit accepts the documented SSH/RDP access
    # is translated and then silently dropped.
    local frag="${PROJECT_ROOT}/provision/host/frag/90-finalize.sh"
    assert_file_contains "$frag" '-o vmbr0 -p tcp -d 192.168.100.100 --dport 22 -j ACCEPT'
    assert_file_contains "$frag" '-o vmbr0 -p tcp -d 192.168.100.100 --dport 3389 -j ACCEPT'
}

@test "no dev VM at or above 104 is granted egress" {
    # 104-249 must fall through to the DROP default. Any explicit rule for that
    # range reverses the containment the range boundary exists to provide.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
        '-s 192.168.100.104'
    assert_file_not_contains "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf" \
        '-s 192.168.100.104'
}

@test "the reference ruleset grants each allowed guest each allowed port" {
    # The reference file documents the live policy. If the two drift, a
    # reviewer reading the reference is reading a policy the host does not
    # enforce. Compare the rules, not the comments.
    local conf="${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"
    local ip port
    for ip in 192.168.100.101 192.168.100.102 192.168.100.103; do
        for port in "tcp --dport 53" "tcp --dport 80" "tcp --dport 443"; do
            # shellcheck disable=SC2016
            grep -qE -- "-s ${ip} -p ${port} -j ACCEPT" "$conf" || {
                echo "reference ruleset is missing: ${ip} ${port}" >&2
                return 1
            }
        done
    done
}
