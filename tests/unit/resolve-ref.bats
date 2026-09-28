#!/usr/bin/env bats
# tests/unit/resolve-ref.bats — test resolve_ref_to_sha
#
# The function lives in provision/personalization.sh and is called by both
# build-iso.sh and frag/30-create-guests.sh. It is the single copy: frag/30 used
# to carry a second, slightly different one, so this file is what proves the
# resolution contract that the whole provisioning flow depends on.

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/personalization.sh"
}

teardown() {
    cleanup_mocks
}

@test "resolve_ref_to_sha returns SHA for branch" {
    create_mock "git" \
        '# Only return SHA for refs/heads/ queries
if [[ "$*" == *"refs/heads/"* ]]; then
    echo "abc123def456789012345678901234567890abcd  refs/heads/main"
fi'
    run resolve_ref_to_sha "popiel/nested_dev" "main"
    [ "$output" = "abc123def456789012345678901234567890abcd" ]
}

@test "resolve_ref_to_sha returns SHA for tag" {
    create_mock "git" \
        '# Only return SHA for refs/tags/ queries
if [[ "$*" == *"refs/tags/"* ]]; then
    echo "deadbeef1234567890abcdef1234567890abcdef  refs/tags/v1.0"
fi'
    run resolve_ref_to_sha "popiel/nested_dev" "v1.0"
    [ "$output" = "deadbeef1234567890abcdef1234567890abcdef" ]
}

@test "resolve_ref_to_sha prefers a branch over a tag of the same name" {
    create_mock "git" \
        'if [[ "$*" == *"refs/heads/"* ]]; then
    echo "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  refs/heads/v1.0"
elif [[ "$*" == *"refs/tags/"* ]]; then
    echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  refs/tags/v1.0"
fi'
    run resolve_ref_to_sha "popiel/nested_dev" "v1.0"
    [ "$output" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "resolve_ref_to_sha passes through 40-hex SHA" {
    local sha="deadbeef1234567890abcdef1234567890abcdef"
    run resolve_ref_to_sha "popiel/nested_dev" "$sha"
    [ "$output" = "$sha" ]
}

@test "resolve_ref_to_sha returns empty on unresolvable" {
    create_mock "git" 'echo ""'
    run resolve_ref_to_sha "popiel/nested_dev" "nonexistent"
    [ -z "$output" ]
}

@test "resolve_ref_to_sha succeeds when git is not installed" {
    # The contract that frag/30's private copy violated: under `set -euo
    # pipefail` a missing git used to fail the command substitution and abort
    # guest provisioning part-way, leaving a half-created fleet behind.
    #
    # The simulated PATH has to be built from a directory that is known to hold
    # no git. Naming /usr/bin here, as this test used to, does not simulate
    # anything on a real Linux host, where git IS installed in /usr/bin: the
    # call then reached the network and returned a real SHA. That is how the
    # test passed on Git Bash, where git lives in /mingw64/bin, and then failed
    # under WSL and on any Linux CI runner. Asserting the precondition makes a
    # broken simulation report as a broken test instead of a mystery failure.
    # Everything that narrows PATH runs in a subshell: teardown calls
    # cleanup_mocks, which needs rm, so a PATH left narrowed here would fail
    # teardown with "rm: command not found" and mask the real result.
    (
        local empty="${BATS_TEST_TMPDIR}/no-git-bin"
        mkdir -p "$empty"
        PATH="$empty"

        run command -v git
        [ -z "$output" ] || {
            echo "precondition failed: git is still reachable on the simulated PATH" >&2
            return 1
        }

        run resolve_ref_to_sha "popiel/nested_dev" "main"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    )
}

@test "resolve_ref_to_sha survives a failing git without tripping set -e" {
    # Same contract, second cause: a network error or a GitHub 5xx makes
    # `git ls-remote` exit non-zero. With pipefail and no `|| true` this
    # aborted the caller.
    create_mock "git" 'echo "fatal: unable to access" >&2; exit 128'
    run bash -c 'set -euo pipefail
        source "'"${PROJECT_ROOT}"'/provision/personalization.sh"
        resolve_ref_to_sha popiel/nested_dev main
        echo "survived"'
    [ "$status" -eq 0 ]
    assert_contains "$output" "survived"
}
