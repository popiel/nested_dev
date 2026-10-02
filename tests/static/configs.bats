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

@test "iptables-forwarding.conf passes iptables-restore --test" {
    require_command iptables-restore
    run iptables-restore --test < "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"
    [ "$status" -eq 0 ]
}
