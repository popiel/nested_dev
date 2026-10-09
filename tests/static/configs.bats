#!/usr/bin/env bats
# tests/static/configs.bats — validate config file syntax

load '../lib/helpers'

@test "all guest user-data files parse as YAML" {
    require_command python3
    local ud
    for ud in desktop llm dev; do
        run python3 -c "import yaml; yaml.safe_load(open(r'${PROJECT_ROOT_WIN}/${ud}/user-data/user-data'))"
        if [ "$status" -ne 0 ]; then
            echo "YAML parse failed for ${ud}/user-data/user-data:" >&2
            echo "$output" >&2
            return 1
        fi
    done
}

@test "rendered answer-host.toml parses as TOML" {
    require_command python3
    # The template itself is not valid TOML: the disk-list placeholder is an
    # array contents placeholder, so the array is only well-formed once
    # build-iso.sh substitutes PERSONALIZATION_TARGET_DISKS into it. Parse the
    # rendered file, which is what actually ships (build-iso.sh additionally
    # runs the assistant's own validate-answer on it during every build).
    source "${PROJECT_ROOT}/provision/host/build-iso.sh"
    local out="${BATS_TMPDIR}/rendered-answer.toml"
    PERSONALIZATION_EMAIL="someone@example.com"
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        '"nvme0n1"' "ssh-ed25519 AAAA" "main" 'HASH' 'PERSONAL_HASH' "$out"
    run python3 -c "import tomllib; tomllib.load(open(r'$(win_path "$out")','rb'))"
    [ "$status" -eq 0 ]
}

@test "dnsmasq.conf passes dnsmasq --test" {
    require_command dnsmasq
    run dnsmasq --test -C "${PROJECT_ROOT}/provision/network/dnsmasq.conf"
    [ "$status" -eq 0 ]
}

@test "dnsmasq listens where the host resolver points" {
    # frag/90 writes nameserver 127.0.0.1 into /etc/resolv.conf (pinned by the
    # e2e), so a dnsmasq bound to vmbr0 alone leaves every guest resolving
    # fine while the host itself cannot resolve anything. Both dnsmasq
    # sources — the reference config and the heredoc frag/28 installs — must
    # bind localhost as well as the bridge.
    assert_file_contains "${PROJECT_ROOT}/provision/network/dnsmasq.conf" \
        'interface=lo'
    local heredoc
    heredoc="$(sed -n "/nested_dev.conf.*DNSMASQ_EOF/,/^DNSMASQ_EOF$/p" \
        "${PROJECT_ROOT}/provision/host/frag/28-network.sh")"
    [ -n "$heredoc" ] || { echo "frag/28 dnsmasq heredoc not found" >&2; return 1; }
    assert_contains "$heredoc" 'interface=lo'
}

@test "dhcp advertises the fleet search domain" {
    # Bare guest names are single-label, which resolvers never send to
    # unicast DNS — without option 119 only FQDNs resolve. Same two sources
    # as the tests above.
    local ref="${PROJECT_ROOT}/provision/network/dnsmasq.conf"
    assert_file_contains "$ref" 'dhcp-option=option:domain-search,wolfskeep.com'
    local heredoc
    heredoc="$(sed -n "/nested_dev.conf.*DNSMASQ_EOF/,/^DNSMASQ_EOF$/p" \
        "${PROJECT_ROOT}/provision/host/frag/28-network.sh")"
    [ -n "$heredoc" ] || { echo "frag/28 dnsmasq heredoc not found" >&2; return 1; }
    assert_contains "$heredoc" 'dhcp-option=option:domain-search,wolfskeep.com'
}

@test "public upstreams are a fallback tier, not the policy" {
    # The lease-provided resolver is primary; the public servers exist only
    # for a broken LAN resolver (observed: TCP/53 answered, UDP/53
    # blackholed). Pin both halves so a future edit can neither drop the
    # fallback (re-breaking everything behind a bad router) nor drop the
    # lease path (silently promoting last-resort servers to everyday use).
    # Same two sources as the localhost test above.
    local ref="${PROJECT_ROOT}/provision/network/dnsmasq.conf"
    assert_file_contains "$ref" 'resolv-file=/run/resolv.conf'
    assert_file_contains "$ref" 'server=9.9.9.9'
    assert_file_contains "$ref" 'server=1.1.1.1'
    local heredoc
    heredoc="$(sed -n "/nested_dev.conf.*DNSMASQ_EOF/,/^DNSMASQ_EOF$/p" \
        "${PROJECT_ROOT}/provision/host/frag/28-network.sh")"
    [ -n "$heredoc" ] || { echo "frag/28 dnsmasq heredoc not found" >&2; return 1; }
    assert_contains "$heredoc" 'resolv-file=/run/resolv.conf'
    assert_contains "$heredoc" 'server=9.9.9.9'
    assert_contains "$heredoc" 'server=1.1.1.1'
}

@test "iptables-forwarding.conf passes iptables-restore --test" {
    require_command iptables-restore
    run iptables-restore --test < "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"
    [ "$status" -eq 0 ]
}

@test "every DNAT has a filter admission for its rewritten tuple" {
    # NAT rewrites before the filter runs, so a DNAT is only as good as the
    # rule admitting the REWRITTEN destination — never the original port.
    # Both rule sources are checked: the fragment applying the live state and
    # the reference the boot restore uses. Line continuations are joined
    # first, so multi-line rules match as one.
    local file joined ip port
    for file in "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
                "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"; do
        joined="$(sed -e ':a' -e '/\\$/N; s/\\\n/ /; ta' "$file")"
        while read -r ip port; do
            [ -n "$ip" ] || continue
            printf '%s\n' "$joined" \
                | grep -qE -- "-d ${ip} .*--dport ${port} .*-j ACCEPT" || {
                echo "$file: DNAT to ${ip}:${port} admits nothing for the rewritten tuple" >&2
                return 1
            }
        done < <(printf '%s\n' "$joined" \
            | grep -oE -- '--to-destination [0-9.]+:[0-9]+' \
            | sed -E 's/--to-destination ([0-9.]+):([0-9]+)/\1 \2/')
    done
}

@test "no DNAT targets the host itself" {
    # Host services are served by listening (sshd on 2222), never by
    # DNAT-to-self: the filter sees the rewritten port, so the admitting rule
    # for the original port can never match — host SSH from the LAN never
    # admitted a connection under that combination, in any topology.
    local file
    for file in "${PROJECT_ROOT}/provision/host/frag/90-finalize.sh" \
                "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"; do
        # The trailing colon matters: without it 192.168.100.1 also matches
        # the desktop's 192.168.100.100.
        if grep -q -- "DNAT --to-destination 192.168.100.1:" "$file"; then
            echo "$file: DNAT-to-self for host SSH is back" >&2
            return 1
        fi
    done
}
