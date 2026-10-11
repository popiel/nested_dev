#!/usr/bin/env bats
# tests/unit/personalization.bats — contract of provision/personalization.sh
#
# These tests assert the *contract* the rest of the system relies on, not the
# concrete identity values. The identity is the fork owner's to change
# (specs/05 §9), so no test may hardcode a username, name, email or UID.
# What must hold for every fork: sourcing the file defines every required
# variable, and none is left empty.

load '../lib/helpers'

# The variables first-boot.sh and frag/30 read. TARGET_DISKS is deliberately
# excluded: it is build-host-specific and defaults to empty by design.
REQUIRED_VARS=(
    PERSONALIZATION_USERNAME
    PERSONALIZATION_FULLNAME
    PERSONALIZATION_EMAIL
    PERSONALIZATION_UID
    PERSONALIZATION_GID
    PERSONALIZATION_HOME
    PERSONALIZATION_REPO
    PERSONALIZATION_REF
)

source_real_personalization() {
    local var
    for var in "${REQUIRED_VARS[@]}"; do
        export "$var"=""
    done
    source "${PROJECT_ROOT}/provision/personalization.sh"
}

# Covers: R-05.1.2, A-05.1
@test "sourcing personalization.sh defines every required variable" {
    local var missing=()
    source_real_personalization
    for var in "${REQUIRED_VARS[@]}"; do
        [ -n "${!var}" ] || missing+=("$var")
    done
    [ "${#missing[@]}" -eq 0 ] || {
        printf 'left undefined or empty: %s\n' "${missing[*]}" >&2
        return 1
    }
}

# Covers: R-05.1.3, A-05.1
@test "PERSONALIZATION_HOME derives from PERSONALIZATION_USERNAME" {
    source_real_personalization
    [ "$PERSONALIZATION_HOME" = "/home/${PERSONALIZATION_USERNAME}" ]
}

# Covers: R-05.8.3, R-09.3.7, I-05.5, A-05.15
@test "resolve_ref_to_sha is defined in exactly one script" {
    # frag/30 sources personalization.sh and calls resolve_ref_to_sha. A second
    # copy is how the two drifted: frag/30's lacked the `command -v git` guard
    # and the `|| true` on the git call, so under `set -euo pipefail` a missing
    # git or a network failure aborted guest provisioning mid-flight.
    local found
    found=$(grep -rln '^resolve_ref_to_sha()' "${PROJECT_ROOT}/provision" || true)
    local count
    count=$(printf '%s\n' "$found" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        printf 'expected exactly one definition, found %s:\n%s\n' \
            "$count" "$found" >&2
        return 1
    fi
    assert_contains "$found" "provision/personalization.sh"
}
