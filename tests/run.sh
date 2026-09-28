#!/usr/bin/env bash
# tests/run.sh — run the test suite (static + unit)
#
# Usage:
#   tests/run.sh                 # every suite
#   tests/run.sh --fast          # static only, for pre-commit
#   tests/run.sh tests/unit/gpu-detect.bats              # one suite
#   tests/run.sh tests/unit/*.bats                       # several suites
#
# Every suite runs as `bats -T --formatter tap` and is handed to tests/timing.sh,
# so each run leaves a per-test timing record under tests/.timing/ and prints a
# report splitting time inside test bodies from bats' own per-test overhead.
#
# On Windows, run this through tests/run-wsl.sh: git-bash/MSYS spends ~65ms on
# every process spawn, which makes the suite take around 15 minutes, while the
# same suite under WSL takes under 20 seconds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TIMING="${TIMING_DIR:-${SCRIPT_DIR}/.timing}"

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- Arguments ---
FAST=0
FILES=()
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *) FILES+=("$arg") ;;
    esac
done

# --- Dependency check ---
MISSING=""
for cmd in bats shellcheck python3; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="${MISSING} ${cmd}"
done

if [ -n "$MISSING" ]; then
    echo "ERROR: Missing required tools:${MISSING}" >&2
    echo "" >&2
    echo "Install on Debian/Ubuntu:" >&2
    echo "  sudo apt-get install bats shellcheck python3 python3-yaml" >&2
    echo "" >&2
    echo "Install bats on macOS:" >&2
    echo "  brew install bats-core" >&2
    echo "" >&2
    echo "On Windows, use tests/run-wsl.sh, which runs the suite in WSL." >&2
    exit 1
fi

# Optional tools (tests skip gracefully if absent)
OPTIONAL_CMDS="dnsmasq iptables-restore hadolint"
for cmd in $OPTIONAL_CMDS; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  [ok] $cmd found"
    else
        echo "  [--] $cmd not found (some tests will skip)"
    fi
done

cd "$ROOT_DIR"

# --- Suite list ---
# label:path. The label is what the timing record keys on, so keep it stable.
ALL_SUITES=(
    "lint:tests/static/lint.bats"
    "configs:tests/static/configs.bats"
    "invariants:tests/static/invariants.bats"
    "personalization:tests/unit/personalization.bats"
    "resolve-ref:tests/unit/resolve-ref.bats"
    "gpu-detect:tests/unit/gpu-detect.bats"
    "frag10-iommu:tests/unit/frag10-iommu.bats"
    "frag25-vmctl:tests/unit/frag25-vmctl.bats"
    "first-boot-user:tests/unit/first-boot-user.bats"
    "build-iso:tests/unit/build-iso.bats"
    "timing:tests/unit/timing.bats"
)
STATIC_SUITES=(
    "lint:tests/static/lint.bats"
    "configs:tests/static/configs.bats"
    "invariants:tests/static/invariants.bats"
)

SUITES=()
if [ "${#FILES[@]}" -gt 0 ]; then
    # Explicit files win over --fast: the caller asked for something specific.
    for f in "${FILES[@]}"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: no such test file: $f" >&2
            exit 2
        fi
        # Label from the basename so the timing key matches the built-in labels.
        SUITES+=("$(basename "$f" .bats):$f")
    done
    RUN_LABEL="subset"
elif [ "$FAST" -eq 1 ]; then
    SUITES=("${STATIC_SUITES[@]}")
    RUN_LABEL="static"
else
    SUITES=("${ALL_SUITES[@]}")
    RUN_LABEL="full"
fi

echo ""
echo "=== nested_dev test suite ==="
echo "    ROOT: $ROOT_DIR"
echo "    MODE: $RUN_LABEL (${#SUITES[@]} suite(s))"
echo ""

# --- Result counters, reported in the machine-readable block at the end ---
SUITES_TOTAL=0
SUITES_PASSED=0
SUITES_FAILED=0
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Timing must never be the reason a test run fails. If timing.sh breaks, the
# suites still run and still report their own results.
run_timing() {
    if ! bash "${SCRIPT_DIR}/timing.sh" "$@"; then
        printf 'warning: timing step failed (%s); continuing\n' "$*" >&2
    fi
}

# run_suite <label> <path/to/file.bats>
# Runs one suite, records its timing, and prints a one-line summary. A failing
# suite prints its full TAP output so per-test diagnostics stay visible.
run_suite() {
    local label="$1" file="$2"
    local tap_file wall_start wall_ms rc ok_count fail_count skip_count passed_count
    local total_count in_test_ms status detail

    tap_file="$(mktemp "${TMPDIR:-/tmp}/nested-dev-tap-XXXXXX")"

    wall_start="$(date +%s%N)"
    set +e
    bats -T --formatter tap "$file" > "$tap_file" 2>&1
    rc=$?
    set -e
    wall_ms=$(( ($(date +%s%N) - wall_start) / 1000000 ))

    ok_count="$(grep -c '^ok ' "$tap_file" 2>/dev/null || true)"
    fail_count="$(grep -c '^not ok ' "$tap_file" 2>/dev/null || true)"
    # Count skips only on ok lines, because that is the only place bats puts
    # them. Restricting the pattern keeps the arithmetic below sound even if
    # bats ever emits a diagnostic comment containing the marker.
    skip_count="$(grep -c '^ok .*# skip' "$tap_file" 2>/dev/null || true)"
    : "${ok_count:=0}" "${fail_count:=0}" "${skip_count:=0}"
    # bats reports a skip as `ok 3 # skip reason`, so ok_count includes them.
    # Reporting ok_count as "passed" would claim a test ran that never did.
    passed_count=$((ok_count - skip_count))
    total_count=$((ok_count + fail_count))

    run_timing parse "$label" "$tap_file" "$wall_ms"

    # bats appends the skip reason AFTER the timing, as in
    #   ok 3 a test in 941ms # skip no shellcheck here
    # so the skip marker has to be stripped before the end-anchored match
    # below, the same order tests/timing.sh uses. Without this the skipped
    # tests' time is silently dropped from the per-suite total.
    #
    # `|| true` is load-bearing. Under `set -e` with `pipefail` a pipeline whose
    # last stage succeeds still returns non-zero when an earlier stage failed,
    # and an assignment from it aborts the script. A suite whose TAP carries no
    # timing at all — a file bats cannot parse, say — matched nothing, the
    # first grep returned 1, and run.sh died with no output and no result
    # block, hiding the very error the developer needed to see.
    in_test_ms="$( { sed 's/[[:space:]]*# skip.*$//' "$tap_file" 2>/dev/null \
        | grep -oE 'in [0-9]+ms$' \
        | grep -oE '[0-9]+' \
        | awk '{ s += $1 } END { print s + 0 }'; } || true )"
    : "${in_test_ms:=0}"

    SUITES_TOTAL=$((SUITES_TOTAL + 1))
    TESTS_TOTAL=$((TESTS_TOTAL + total_count))
    TESTS_PASSED=$((TESTS_PASSED + passed_count))
    TESTS_FAILED=$((TESTS_FAILED + fail_count))
    TESTS_SKIPPED=$((TESTS_SKIPPED + skip_count))

    status="ok"
    detail="${passed_count} passed"
    if [ "$fail_count" -gt 0 ]; then
        status="FAILED"
        detail="${detail}, ${fail_count} failed"
    elif [ "$rc" -ne 0 ]; then
        # A non-zero exit with no `not ok` line is a suite that could not run:
        # a file bats cannot parse, or a failure before the first test. It is
        # not a pass just because no assertion was recorded.
        status="FAILED"
        detail="${detail}, suite could not run"
    fi
    if [ "$status" = "FAILED" ]; then
        SUITES_FAILED=$((SUITES_FAILED + 1))
    else
        SUITES_PASSED=$((SUITES_PASSED + 1))
    fi
    if [ "$skip_count" -gt 0 ]; then
        detail="${detail}, ${skip_count} skipped"
    fi

    printf '  %-18s %-9s %-28s %6.1fs wall  %5.1fs in tests\n' \
        "$label" "$status" "$detail" \
        "$(awk -v m="$wall_ms" 'BEGIN { print m / 1000 }')" \
        "$(awk -v m="$in_test_ms" 'BEGIN { print m / 1000 }')"

    # Print the suite's full TAP when anything went wrong: the ok/not-ok lines
    # alone do not say which assertion failed. The braces matter — `a || b && c`
    # groups as `(a || b) && c`, which silently skipped this branch whenever a
    # test had actually failed, hiding exactly the output needed to debug it.
    if [ "$fail_count" -gt 0 ] || { [ "$rc" -ne 0 ] && [ "$fail_count" -eq 0 ]; }; then
        echo ""
        sed 's/^/    /' "$tap_file"
        echo ""
    fi

    rm -f "$tap_file"
    return 0
}

for entry in "${SUITES[@]}"; do
    run_suite "${entry%%:*}" "${entry#*:}"
done

run_timing finalize "$RUN_LABEL" "$([ "$SUITES_FAILED" -gt 0 ] && echo 1 || echo 0)"

OVERALL_RC=0
if [ "$SUITES_FAILED" -gt 0 ]; then
    OVERALL_RC=1
    echo "=== failures above ===" >&2
else
    echo "=== all passed ==="
fi

# Machine-readable tally. tests/run-wsl.sh parses this to report the result
# without having to re-read the human-readable output above.
echo ""
echo "=== result ==="
echo "run_mode=$RUN_LABEL"
echo "suites_total=$SUITES_TOTAL"
echo "suites_passed=$SUITES_PASSED"
echo "suites_failed=$SUITES_FAILED"
echo "tests_total=$TESTS_TOTAL"
echo "tests_passed=$TESTS_PASSED"
echo "tests_failed=$TESTS_FAILED"
echo "tests_skipped=$TESTS_SKIPPED"
echo "timing_dir=$TIMING"
echo ""

exit "$OVERALL_RC"
