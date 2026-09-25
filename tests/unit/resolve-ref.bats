#!/usr/bin/env bats
# tests/unit/resolve-ref.bats — test resolve_ref_to_sha from frag/30

load '../lib/helpers'

setup() {
    setup_mock_path
    # Source the function under test (source-guard prevents main from running)
    source "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh"
}

teardown() {
    cleanup_mocks
}

@test "resolve_ref_to_sha returns SHA for branch" {
    cat > "${FIXTURES_DIR}/mock-bin/git" <<'SCRIPT'
#!/bin/bash
# Only return SHA for refs/heads/ queries
if [[ "$*" == *"refs/heads/"* ]]; then
    echo "abc123def456789012345678901234567890abcd  refs/heads/main"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/git"
    run resolve_ref_to_sha "popiel/nested_dev" "main"
    [ "$output" = "abc123def456789012345678901234567890abcd" ]
}

@test "resolve_ref_to_sha returns SHA for tag" {
    cat > "${FIXTURES_DIR}/mock-bin/git" <<'SCRIPT'
#!/bin/bash
# Only return SHA for refs/tags/ queries
if [[ "$*" == *"refs/tags/"* ]]; then
    echo "deadbeef1234567890abcdef1234567890abcdef  refs/tags/v1.0"
fi
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/git"
    run resolve_ref_to_sha "popiel/nested_dev" "v1.0"
    [ "$output" = "deadbeef1234567890abcdef1234567890abcdef" ]
}

@test "resolve_ref_to_sha passes through 40-hex SHA" {
    local sha="deadbeef1234567890abcdef1234567890abcdef"
    run resolve_ref_to_sha "popiel/nested_dev" "$sha"
    [ "$output" = "$sha" ]
}

@test "resolve_ref_to_sha returns empty on unresolvable" {
    cat > "${FIXTURES_DIR}/mock-bin/git" <<'SCRIPT'
#!/bin/bash
echo ""
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/git"
    run resolve_ref_to_sha "popiel/nested_dev" "nonexistent"
    [ -z "$output" ]
}
