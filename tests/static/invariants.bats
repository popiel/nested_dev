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

@test "host templates carry the placeholders their renderer substitutes" {
    # Each entry is "file|placeholder". A missing placeholder does not fail the
    # build; it ships an unsubstituted token into the answer file or the host
    # bootstrap, where it surfaces as a broken install.
    local entry file placeholder
    for entry in \
        "provision/host/answer-host.toml|__GITHUB_REF__" \
        "provision/host/answer-host.toml|__ROOT_SSH_KEY__" \
        "provision/host/answer-host.toml|__ROOT_PASSWORD_HASH__" \
        "provision/host/first-boot.sh|__PERSONALIZATION_PASSWORD_HASH__" \
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
    # Scoped to the source tree and the operator docs: this test and
    # tests/unit/first-boot-user.bats necessarily name the old paths in their
    # negative assertions, and specs/09 quotes them in documenting the rename.
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
    # reason instead of creating guests with a blank username.
    local frag30="${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
    assert_file_contains "$frag30" \
        'PERSONALIZATION_USERNAME or PERSONALIZATION_FULLNAME not set'
    assert_file_contains "$frag30" \
        'Personalization password hash not found: ${PERSONALIZATION_HASH_FILE}'
}

@test "data volume size is 500 GB" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'DATA_VOL_SIZE=500'
}
