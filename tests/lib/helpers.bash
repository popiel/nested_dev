#!/usr/bin/env bash
# tests/lib/helpers.bash — common test helpers for bats

# Project root (two levels up from tests/lib/)
export PROJECT_ROOT
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Windows-compatible path for Python (converts /c/... to C:/...)
export PROJECT_ROOT_WIN
if command -v cygpath >/dev/null 2>&1; then
    PROJECT_ROOT_WIN="$(cygpath -w "$PROJECT_ROOT")"
else
    PROJECT_ROOT_WIN="$PROJECT_ROOT"
fi

# Convert any path to a form a native Windows binary (e.g. python3) can open.
# No-op outside MSYS/Git Bash. Use for any path handed to a native tool.
win_path() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$p"
    else
        printf '%s\n' "$p"
    fi
}

# Path to test fixtures
export FIXTURES_DIR="${PROJECT_ROOT}/tests/fixtures"

# Set up mock PATH with test fixtures
setup_mock_path() {
    mkdir -p "${FIXTURES_DIR}/mock-bin"
    export PATH="${FIXTURES_DIR}/mock-bin:${PATH}"
}

# Clean up mock PATH
teardown_mock_path() {
    export PATH="${PATH#*${FIXTURES_DIR}/mock-bin:}"
}

# Create a mock script that outputs fixed content
# Usage: create_mock "command" "output_content"
create_mock() {
    local cmd="$1" content="$2"
    mkdir -p "${FIXTURES_DIR}/mock-bin"
    printf '#!/bin/bash\n%s\n' "$content" > "${FIXTURES_DIR}/mock-bin/${cmd}"
    chmod +x "${FIXTURES_DIR}/mock-bin/${cmd}"
}

# Create a mock script that reads from a fixture file
# Usage: create_mock_from_file "command" "fixture_file"
create_mock_from_file() {
    local cmd="$1" fixture="$2"
    mkdir -p "${FIXTURES_DIR}/mock-bin"
    printf '#!/bin/bash\ncat "%s"\n' "$fixture" > "${FIXTURES_DIR}/mock-bin/${cmd}"
    chmod +x "${FIXTURES_DIR}/mock-bin/${cmd}"
}

# Clean up all mock scripts
cleanup_mocks() {
    rm -rf "${FIXTURES_DIR}/mock-bin"
}

# Install a fixture script as a mock command on the mock PATH.
# Use this instead of create_mock when the command needs a multi-line body with
# shell control flow, so the mock stays a real readable script rather than an
# escaped string.
# Usage: install_mock "lspci" "mock-lspci.sh"
install_mock() {
    local cmd="$1" script="$2"
    mkdir -p "${FIXTURES_DIR}/mock-bin"
    cp "${FIXTURES_DIR}/${script}" "${FIXTURES_DIR}/mock-bin/${cmd}"
    chmod +x "${FIXTURES_DIR}/mock-bin/${cmd}"
}

# Assert that a string contains a substring
# Usage: assert_contains "haystack" "needle"
assert_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Expected to contain: $needle" >&2
        echo "Actual: $haystack" >&2
        return 1
    fi
}

# Assert that a string does NOT contain a substring
# Usage: assert_not_contains "haystack" "needle"
assert_not_contains() {
    local haystack="$1" needle="$2"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "Expected NOT to contain: $needle" >&2
        echo "Actual: $haystack" >&2
        return 1
    fi
}

# Assert a file contains a literal string.
# Literal (grep -F) by default: needles here are shell and YAML source text, so
# they routinely contain [ $ { ( * and ? that a regex would reinterpret — a
# mid-pattern $ is an anchor, a bracketed [A-Z_] is a character class. A
# pattern-shaped needle that silently matched nothing was the failure mode this
# replaces. Use assert_file_matches when a regex is genuinely intended.
# The -- is required: needles may legitimately start with a dash (e.g. "-v ...").
# Usage: assert_file_contains "filepath" "text"
assert_file_contains() {
    local filepath="$1" needle="$2"
    if ! grep -qF -- "$needle" "$filepath" 2>/dev/null; then
        echo "File $filepath does not contain: $needle" >&2
        return 1
    fi
}

# Assert a file contains a string matching an extended regex.
# Usage: assert_file_matches "filepath" "regex"
assert_file_matches() {
    local filepath="$1" regex="$2"
    if ! grep -qE -- "$regex" "$filepath" 2>/dev/null; then
        echo "File $filepath does not match: $regex" >&2
        return 1
    fi
}

# Assert a file does NOT match an extended regex.
# Use this for negative rules that are only expressible as a pattern, e.g.
# rejecting "chpasswd -e" on a line that also mentions root. With a literal
# matcher such a rule passes for the wrong reason: nothing in the file
# contains the characters ".*" either.
# Usage: assert_file_not_matches "filepath" "regex"
assert_file_not_matches() {
    local filepath="$1" regex="$2"
    if grep -qE -- "$regex" "$filepath" 2>/dev/null; then
        echo "File $filepath unexpectedly matches: $regex" >&2
        return 1
    fi
}

# Assert file does NOT contain a literal string
# Usage: assert_file_not_contains "filepath" "text"
assert_file_not_contains() {
    local filepath="$1" needle="$2"
    if grep -qF -- "$needle" "$filepath" 2>/dev/null; then
        echo "File $filepath unexpectedly contains: $needle" >&2
        return 1
    fi
}

# Skip test if a command is not available
# Usage: require_command "shellcheck"
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        skip "$cmd not installed"
    fi
}

# Source a script's functions without executing main
# Usage: source_functions "path/to/script.sh"
source_functions() {
    local script="$1"
    # Source the file; the source-guard prevents main() from running
    # Functions become available in the current shell
    source "$script" 2>/dev/null || true
}
