#!/usr/bin/env bats
# tests/static/lint.bats — shellcheck all shell scripts

load '../lib/helpers'

@test "shellcheck passes on all .sh scripts" {
    require_command shellcheck
    local fail=0
    for script in $(find "$PROJECT_ROOT" -name '*.sh' \
        -not -path '*/tests/*' \
        -not -path '*/output/*' \
        -not -path '*/.git/*'); do
        # SC1091: can't follow dynamic source paths (expected)
        # SC2034: unused variables in sourced config files (expected)
        # SC2016: intentional single quotes in echo (e.g. .bashrc PATH export)
        # SC2166: prefer [ p -a q ] over [ p ] && [ q ] (project style choice)
        run shellcheck -x -s bash -e SC1091,SC2034,SC2016,SC2166 "$script"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: $script" >&2
            echo "$output" >&2
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

@test "shellcheck passes on extension-less bash scripts" {
    require_command shellcheck
    local fail=0
    for script in \
        dev/tools/nested \
        dev/tools/dev-refresh-images \
        provision/host/vmctl/vmctl-host; do
        full_path="${PROJECT_ROOT}/${script}"
        [ -f "$full_path" ] || continue
        head -1 "$full_path" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash' || continue
        run shellcheck -x -s bash -e SC1091,SC2034,SC2166 "$full_path"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: $script" >&2
            echo "$output" >&2
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}
