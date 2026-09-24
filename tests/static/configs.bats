#!/usr/bin/env bats
# tests/static/configs.bats — validate config file syntax

load '../lib/helpers'

@test "desktop user-data parses as YAML" {
    require_command python3
    run python3 -c "import yaml; yaml.safe_load(open('${PROJECT_ROOT}/desktop/user-data/user-data'))"
    [ "$status" -eq 0 ]
}

@test "llm user-data parses as YAML" {
    require_command python3
    run python3 -c "import yaml; yaml.safe_load(open('${PROJECT_ROOT}/llm/user-data/user-data'))"
    [ "$status" -eq 0 ]
}

@test "dev user-data parses as YAML" {
    require_command python3
    run python3 -c "import yaml; yaml.safe_load(open('${PROJECT_ROOT}/dev/user-data/user-data'))"
    [ "$status" -eq 0 ]
}

@test "answer-host.toml parses as TOML" {
    require_command python3
    run python3 -c "import tomllib; tomllib.load(open('${PROJECT_ROOT}/provision/host/answer-host.toml','rb'))"
    [ "$status" -eq 0 ]
}

@test "dnsmasq.conf passes dnsmasq --test" {
    require_command dnsmasq
    run dnsmasq --test -C "${PROJECT_ROOT}/provision/network/dnsmasq.conf"
    [ "$status" -eq 0 ]
}

@test "iptables-forwarding.conf passes iptables-restore --test" {
    require_command iptables-restore
    run iptables-restore --test < "${PROJECT_ROOT}/provision/network/iptables-forwarding.conf"
    [ "$status" -eq 0 ]
}
