#!/usr/bin/env bats
# tests/unit/personalization.bats — test personalization.sh sourcing

load '../lib/helpers'

setup() {
    export PERSONALIZATION_USERNAME=""
    export PERSONALIZATION_FULLNAME=""
    export PERSONALIZATION_EMAIL=""
    export PERSONALIZATION_UID=""
    export PERSONALIZATION_GID=""
    export PERSONALIZATION_HOME=""
    export PERSONALIZATION_REPO=""
    export PERSONALIZATION_REF=""
}

@test "personalization.sh sets PERSONALIZATION_USERNAME" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_USERNAME" = "popiel" ]
}

@test "personalization.sh sets PERSONALIZATION_UID" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_UID" = "1401" ]
}

@test "personalization.sh sets PERSONALIZATION_GID" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_GID" = "1401" ]
}

@test "personalization.sh sets PERSONALIZATION_HOME" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_HOME" = "/home/popiel" ]
}

@test "personalization.sh sets PERSONALIZATION_REPO" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_REPO" = "popiel/nested_dev" ]
}

@test "personalization.sh sets PERSONALIZATION_REF" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_REF" = "main" ]
}

@test "personalization.sh sets PERSONALIZATION_FULLNAME" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_FULLNAME" = "T. Alexander Popiel" ]
}

@test "personalization.sh sets PERSONALIZATION_EMAIL" {
    source "${FIXTURES_DIR}/personalization.sh"
    [ "$PERSONALIZATION_EMAIL" = "tapopiel@gmail.com" ]
}
