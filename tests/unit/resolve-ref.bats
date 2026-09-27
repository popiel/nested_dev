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
    # A PATH with no git at all is the honest way to simulate that.
    setup_mock_path
    rm -f "${FIXTURES_DIR}/mock-bin/git"
    PATH="${FIXTURES_DIR}/mock-bin:/usr/bin:/bin"
    run resolve_ref_to_sha "popiel/nested_dev" "main"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
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
