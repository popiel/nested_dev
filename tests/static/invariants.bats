#!/usr/bin/env bats
# tests/static/invariants.bats — check repo-wide invariants

load '../lib/helpers'

@test "no hardcoded popiel outside personalization.sh" {
    local result
    result=$(grep -r 'popiel' --include='*.sh' --include='*.toml' --include='*.conf' \
        --include='*.yml' --include='*.yaml' "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v 'tests/fixtures/' \
        | grep -v '.git/' \
        | grep -v 'popiel/nested_dev' || true)
    [ -z "$result" ]
}

@test "no hardcoded tapopiel@gmail.com outside personalization.sh" {
    local result
    result=$(grep -r 'tapopiel@gmail.com' --include='*.sh' --include='*.toml' \
        "$PROJECT_ROOT" 2>/dev/null \
        | grep -v 'provision/personalization.sh' \
        | grep -v 'tests/fixtures/' \
        | grep -v '.git/' || true)
    [ -z "$result" ]
}

@test "frag/30 contains OS disk sizes from decision table" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'local-lvm:40,size=40G'
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'local-lvm:80,size=80G'
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
    for ud in desktop llm dev; do
        assert_file_contains "${PROJECT_ROOT}/${ud}/user-data/user-data" '__PERSONALIZATION_USERNAME__'
        assert_file_contains "${PROJECT_ROOT}/${ud}/user-data/user-data" '__PERSONALIZATION_FULLNAME__'
        assert_file_contains "${PROJECT_ROOT}/${ud}/user-data/user-data" 'CHANGE_ME_HASHED'
    done
}

@test "answer-host.toml contains __GITHUB_REF__" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" '__GITHUB_REF__'
}

@test "answer-host.toml contains __ROOT_SSH_KEY__" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" '__ROOT_SSH_KEY__'
}

@test "frag/30 sources personalization.sh from correct path" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" '/root/provision/personalization.sh'
}

@test "frag/30 aborts when personalization vars are empty" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'exit 1'
}

@test "data volume size is 500 GB" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DATA_VOL_SIZE=500'
}
