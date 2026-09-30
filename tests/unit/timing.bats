#!/usr/bin/env bats
# tests/unit/timing.bats — tests/timing.sh
#
# Covers the parser against the exact TAP shapes bats -T emits. The edge cases
# here are the ones that would silently corrupt a timing record: a test whose
# name itself ends in "in <n>ms", bats' skip marker arriving after the timing
# suffix, and result lines that carry no timing at all.

load '../lib/helpers'

setup() {
    TIMING_DIR="${BATS_TEST_TMPDIR}/timing"
    export TIMING_DIR
    mkdir -p "$TIMING_DIR"
    TAP="${BATS_TEST_TMPDIR}/out.tap"
    TIMING="${BATS_TEST_PROJECT_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}/tests/timing.sh"
    if [ ! -f "$TIMING" ]; then
        TIMING="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/timing.sh"
    fi
}

# Write TAP text to $TAP and parse it as suite "unit" with the given wall time.
# Leaves the resulting records in $TIMING_DIR/current.tsv.
parse() {
    cat > "$TAP"
    run bash "$TIMING" parse "unit" "$TAP" "${1:-1000}"
    [ "$status" -eq 0 ] || {
        echo "parse failed: $output" >&2
        return 1
    }
}

@test "timing.sh is syntactically valid" {
    run bash -n "$TIMING"
    [ "$status" -eq 0 ]
}

@test "parse records suite, number, status, ms, wall and name" {
    parse 1000 <<'EOF'
1..1
ok 1 a passing test in 632ms
EOF
    [ "$(wc -l < "$TIMING_DIR/current.tsv")" -eq 1 ]
    run cat "$TIMING_DIR/current.tsv"
    assert_contains "$output" "unit	1	ok	632	1000	a passing test"
}

@test "parse records a failing test" {
    parse 1000 <<'EOF'
1..1
not ok 2 a failing test in 679ms
EOF
    run cat "$TIMING_DIR/current.tsv"
    assert_contains "$output" "unit	2	not ok	679	1000	a failing test"
}

@test "parse records a skipped test and keeps the timing" {
    parse 1000 <<'EOF'
1..1
ok 3 a skipped test in 941ms # skip no shellcheck here
EOF
    run cat "$TIMING_DIR/current.tsv"
    assert_contains "$output" "unit	3	skip	941	1000	a skipped test"
}

@test "parse strips the skip reason from the recorded name" {
    parse 1000 <<'EOF'
1..1
ok 1 something in 5ms # skip because reasons
EOF
    run cut -f6 "$TIMING_DIR/current.tsv"
    [ "$output" = "something" ]
}

@test "parse keeps a test name that itself contains an in <n>ms substring" {
    parse 1000 <<'EOF'
1..1
ok 4 a name containing in 42ms inside in 628ms
EOF
    run cut -f6 "$TIMING_DIR/current.tsv"
    [ "$output" = "a name containing in 42ms inside" ]
    run cut -f4 "$TIMING_DIR/current.tsv"
    [ "$output" = "628" ]
}

@test "parse tolerates a result line with no timing suffix" {
    parse 1000 <<'EOF'
1..1
not ok 1 bats-gather-tests
EOF
    run cat "$TIMING_DIR/current.tsv"
    assert_contains "$output" "unit	1	not ok		1000	bats-gather-tests"
}

@test "parse ignores the plan line and bats comment diagnostics" {
    parse 1000 <<'EOF'
1..2
# (in test file /tmp/x.bats, line 3)
#   `@test "a failing test" { false; }' failed
ok 1 fine in 100ms
EOF
    [ "$(wc -l < "$TIMING_DIR/current.tsv")" -eq 1 ]
    run cut -f6 "$TIMING_DIR/current.tsv"
    [ "$output" = "fine" ]
}

@test "parse appends to an existing record rather than truncating" {
    parse 1000 <<'EOF'
1..1
ok 1 first in 10ms
EOF
    parse 2000 <<'EOF'
1..1
ok 1 second in 20ms
EOF
    [ "$(wc -l < "$TIMING_DIR/current.tsv")" -eq 2 ]
}

@test "parse rejects a missing TAP file" {
    run bash "$TIMING" parse "unit" "${BATS_TEST_TMPDIR}/does-not-exist.tap" 1000
    [ "$status" -ne 0 ]
    assert_contains "$output" "no such TAP file"
}

@test "finalize rotates current into last and starts a fresh current" {
    parse 1000 <<'EOF'
1..1
ok 1 first in 10ms
EOF
    run bash "$TIMING" finalize "unit-run" 0
    [ "$status" -eq 0 ]
    [ -f "$TIMING_DIR/last.tsv" ]
    [ ! -s "$TIMING_DIR/current.tsv" ]
    run cut -f6 "$TIMING_DIR/last.tsv"
    [ "$output" = "first" ]
}

@test "finalize records a run summary row" {
    parse 5000 <<'EOF'
1..2
ok 1 one in 100ms
ok 2 two in 200ms
EOF
    bash "$TIMING" finalize "summary-run" 0 >/dev/null
    run cat "$TIMING_DIR/runs.tsv"
    assert_contains "$output" "summary-run"
    # 2 tests, 0 failed, 0 skipped, 5000ms wall, 300ms in tests
    assert_contains "$output" "	2	0	0	5000	300	"
}

@test "finalize records a non-zero exit code for a failed run" {
    parse 1000 <<'EOF'
1..1
not ok 1 broke in 10ms
EOF
    bash "$TIMING" finalize "failing-run" 1 >/dev/null
    run cat "$TIMING_DIR/runs.tsv"
    assert_contains "$output" "failing-run"
    assert_contains "$output" "	1	"
}

@test "report splits wall time from time inside test bodies" {
    parse 10000 <<'EOF'
1..2
ok 1 one in 100ms
ok 2 two in 200ms
EOF
    bash "$TIMING" finalize "split" 0 >/dev/null
    run bash "$TIMING" report
    [ "$status" -eq 0 ]
    assert_contains "$output" "harness"
    # 10000ms wall, 300ms in tests => 9700ms unattributed, 97%
    assert_contains "$output" "9.70s"
    assert_contains "$output" "97%"
}

@test "report breaks the harness overhead down per suite" {
    parse 4000 <<'EOF'
1..1
ok 1 one in 100ms
EOF
    bash "$TIMING" finalize "per-suite" 0 >/dev/null
    run bash "$TIMING" report
    assert_contains "$output" "unit"
    assert_contains "$output" "harness"
}

@test "slowest returns tests ordered by time descending" {
    parse 9000 <<'EOF'
1..3
ok 1 quick in 10ms
ok 2 slow in 5000ms
ok 3 middling in 900ms
EOF
    bash "$TIMING" finalize "slowest" 0 >/dev/null
    run bash "$TIMING" slowest 3
    [ "$status" -eq 0 ]
    # Assert on the ms (field 4) and name (field 6) explicitly, so a change to
    # the record layout fails here instead of silently mislabelling the report.
    [ "$(printf '%s\n' "$output" | cut -f4 | tr '\n' ' ')" = "5000 900 10 " ]
    [ "$(printf '%s\n' "$output" | cut -f6 | tr '\n' ' ')" = "slow middling quick " ]
}

@test "slowest respects the requested limit" {
    parse 9000 <<'EOF'
1..3
ok 1 a in 10ms
ok 2 b in 2000ms
ok 3 c in 3000ms
EOF
    bash "$TIMING" finalize "limit" 0 >/dev/null
    run bash "$TIMING" slowest 2
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
    [ "$(printf '%s\n' "$output" | cut -f6 | tr '\n' ' ')" = "c b " ]
}

@test "slowest excludes tests that were never measured" {
    parse 4000 <<'EOF'
1..2
ok 1 measured in 5000ms
not ok 2 unmeasured
EOF
    bash "$TIMING" finalize "unmeasured" 0 >/dev/null
    run bash "$TIMING" slowest 5
    [ "$(printf '%s\n' "$output" | cut -f6)" = "measured" ]
    assert_not_contains "$output" "unmeasured"
}

@test "report prints the slowest table with the ms and the test name" {
    parse 9000 <<'EOF'
1..2
ok 1 quick in 10ms
ok 2 slow in 5000ms
EOF
    bash "$TIMING" finalize "printed" 0 >/dev/null
    run bash "$TIMING" report
    [ "$status" -eq 0 ]
    assert_contains "$output" "5.00s"
    assert_contains "$output" "slow"
    # No stray record columns may leak into the human-readable table.
    assert_not_contains "$output" "ok	unit"
}

@test "report flags a test that got slower than the previous run" {
    parse 1000 <<'EOF'
1..1
ok 1 regressed in 100ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 regressed in 5000ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "regressed"
    assert_contains "$output" "+4900%"
}

@test "report does not flag jitter on a test that is already fast" {
    # A 9ms -> 16ms change is +70%, but it is noise. Without an absolute floor
    # every run would flag a handful of sub-20ms tests and the regression list
    # would stop being worth reading.
    parse 1000 <<'EOF'
1..1
ok 1 jittery in 9ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 jittery in 16ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "none"
}

@test "report still flags a large absolute slowdown on a fast test" {
    # 40ms -> 900ms clears the default 100ms floor even though the base is
    # small, so a genuinely new bottleneck is not hidden.
    parse 1000 <<'EOF'
1..1
ok 1 wasfast in 40ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 wasfast in 900ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "wasfast"
}

@test "the regression minimum can be overridden" {
    parse 1000 <<'EOF'
1..1
ok 1 tiny in 100ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 tiny in 400ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    # Above the default 100ms floor, so it is reported.
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "tiny"
    # Raise the floor above the 300ms increase and it is suppressed.
    run bash "$TIMING" report --regression-pct 50 --regression-min-ms 1000
    assert_contains "$output" "none"
}

@test "report prints both regression thresholds in its heading" {
    parse 1000 <<'EOF'
1..1
ok 1 a in 10ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 a in 20ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 75 --regression-min-ms 250
    assert_contains "$output" ">= 75% and >= 250ms slower"
}

@test "report does not flag a test that got faster" {
    parse 1000 <<'EOF'
1..1
ok 1 improved in 5000ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..1
ok 1 improved in 100ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "none"
}

@test "report compares by name even when the test number changes" {
    parse 1000 <<'EOF'
1..2
ok 1 first in 10ms
ok 2 moved in 100ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..2
ok 1 moved in 4000ms
ok 2 first in 10ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "moved"
}

@test "report skips comparison when the previous run covered fewer tests" {
    parse 1000 <<'EOF'
1..1
ok 1 only-one in 10ms
EOF
    bash "$TIMING" finalize "run-1" 0 >/dev/null
    parse 1000 <<'EOF'
1..3
ok 1 only-one in 9000ms
ok 2 extra-a in 10ms
ok 3 extra-b in 10ms
EOF
    bash "$TIMING" finalize "run-2" 0 >/dev/null
    run bash "$TIMING" report --regression-pct 50
    assert_contains "$output" "no comparison"
}

@test "report does not crash when there is no previous run" {
    parse 1000 <<'EOF'
1..1
ok 1 alone in 10ms
EOF
    bash "$TIMING" finalize "first-ever" 0 >/dev/null
    run bash "$TIMING" report
    [ "$status" -eq 0 ]
    assert_not_contains "$output" "changes vs previous run"
}

@test "report handles a run with no measured tests" {
    parse 1000 <<'EOF'
1..1
not ok 1 bats-gather-tests
EOF
    bash "$TIMING" finalize "no-measurements" 0 >/dev/null
    run bash "$TIMING" report
    [ "$status" -eq 0 ]
    assert_contains "$output" "no measured tests"
}

@test "history lists recorded runs newest first" {
    parse 1000 <<'EOF'
1..1
ok 1 a in 10ms
EOF
    bash "$TIMING" finalize "older-run" 0 >/dev/null
    parse 2000 <<'EOF'
1..1
ok 1 b in 20ms
EOF
    bash "$TIMING" finalize "newer-run" 0 >/dev/null
    run bash "$TIMING" history
    [ "$status" -eq 0 ]
    assert_contains "$output" "older-run"
    assert_contains "$output" "newer-run"
    # The newer run must be printed above the older one.
    local newer older
    newer="$(printf '%s\n' "$output" | grep -n 'newer-run' | head -1 | cut -d: -f1)"
    older="$(printf '%s\n' "$output" | grep -n 'older-run' | head -1 | cut -d: -f1)"
    [ -n "$newer" ] && [ -n "$older" ]
    [ "$newer" -lt "$older" ]
}

@test "history is empty-safe when nothing has been recorded" {
    run bash "$TIMING" history
    [ "$status" -eq 0 ]
    assert_contains "$output" "no run history"
}

@test "unknown subcommand fails with a usage hint" {
    run bash "$TIMING" not-a-command
    [ "$status" -ne 0 ]
    assert_contains "$output" "unknown command"
}

@test "run.sh is syntactically valid" {
    run bash -n "${BATS_TEST_DIRNAME}/../run.sh"
    [ "$status" -eq 0 ]
}

@test "run.sh asks bats for timing on the suite invocation line" {
    # Match invocation lines only: the header comment also mentions the flag.
    run grep -cE '^[[:space:]]*bats -T --formatter tap' "${BATS_TEST_DIRNAME}/../run.sh"
    [ "$output" -eq 1 ]
}

@test "every suite run.sh names exists on disk" {
    # Guards against run.sh referencing a .bats file that was renamed or deleted.
    # Paths in run.sh are relative to the repo root.
    local root path missing=""
    root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -f "${root}/${path}" ] || missing="${missing} ${path}"
    done < <(grep -oE '"tests/(static|unit)/[a-z0-9-]+\.bats"' "${BATS_TEST_DIRNAME}/../run.sh" \
             | tr -d '"' | sort -u)
    [ -z "$missing" ] || {
        echo "run.sh references missing suites:$missing" >&2
        return 1
    }
}

@test "every suite file in the repo is run by run.sh" {
    # The suite list is built by directory inspection, so this compares the
    # builder's output against the tree rather than a second maintained list
    # against the first: a .bats file the builder never finds would silently
    # never execute. Compared as sets, not counted. Only top-level *.bats in
    # the suite tiers is collected, so scratch work belongs in a subdirectory,
    # not next to the suites.
    local listed actual
    listed="$(bash "${BATS_TEST_DIRNAME}/../run.sh" --list | cut -d: -f2- | sort)"
    actual="$(cd "${BATS_TEST_DIRNAME}/.." && ls static/*.bats unit/*.bats e2e/*.bats \
        | sed 's|^|tests/|' | sort)"
    [ -n "$actual" ] || {
        echo "found no test files to check; the glob is wrong" >&2
        return 1
    }
    if [ "$listed" != "$actual" ]; then
        echo "run.sh --list does not match the repo's test files:" >&2
        diff <(printf '%s\n' "$actual") <(printf '%s\n' "$listed") >&2 || true
        return 1
    fi
}

@test "run.sh's suite labels are unique" {
    # Labels key the timing records: two suites sharing a basename across tiers
    # would merge their histories under one name. The builder refuses to run
    # until that is fixed; this pins the property without requiring a run.
    local dupes
    dupes="$(bash "${BATS_TEST_DIRNAME}/../run.sh" --list | cut -d: -f1 \
        | sort | uniq -d)"
    [ -z "$dupes" ] || {
        echo "duplicate suite labels: $dupes" >&2
        return 1
    }
}

@test "run.sh reports a suite that cannot run instead of dying" {
    # Regression: a .bats file bats cannot parse produces TAP with no `in Nms`
    # on any line. The in-test pipeline's first grep then matched nothing and
    # returned 1, and under `set -e` with `pipefail` that aborted run.sh before
    # it printed anything — no failure, no result block, just exit 1. The
    # developer saw an empty run instead of the syntax error.
    local suite="${BATS_TEST_TMPDIR}/unparseable.bats"
    cat > "$suite" <<'BATS'
@test "unterminated" {
    if [ ; then
BATS
    run env TIMING_DIR="${BATS_TEST_TMPDIR}/timing5" \
        bash "${BATS_TEST_DIRNAME}/../run.sh" "$suite"
    [ "$status" -ne 0 ] || {
        echo "a suite that cannot run was reported as success" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    # The error the developer needs has to survive to the output.
    printf '%s\n' "$output" | grep -q 'syntax error' || {
        echo "bats' parse error was not shown:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    printf '%s\n' "$output" | grep -q '^suites_failed=1$' || {
        echo "the suite was not counted as failed:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
}

@test "a suite that exits non-zero without recording a failure is not a pass" {
    # A stub bats that fails before producing any TAP: rc is non-zero, no test
    # was recorded, so a tally that only looks at `not ok` lines reports a
    # clean pass for a suite that never ran.
    local stub="${BATS_TEST_TMPDIR}/stubbin"
    mkdir -p "$stub"
    cat > "${stub}/bats" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
    chmod +x "${stub}/bats"
    local suite="${BATS_TEST_TMPDIR}/stub-target.bats"
    printf '@test "never runs" { :; }\n' > "$suite"

    run env PATH="${stub}:${PATH}" TIMING_DIR="${BATS_TEST_TMPDIR}/timing6" \
        bash "${BATS_TEST_DIRNAME}/../run.sh" "$suite"
    [ "$status" -ne 0 ] || {
        echo "a suite that exited 3 was reported as success" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    printf '%s\n' "$output" | grep -q '^suites_failed=1$' || {
        echo "suites_failed should be 1 when the suite could not run:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    printf '%s\n' "$output" | grep -q 'suite could not run' || {
        echo "the summary should say the suite could not run:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    # No test ran, so nothing is claimed to have passed or failed.
    printf '%s\n' "$output" | grep -q '^tests_passed=0$' || {
        echo "a suite that never ran must not report passes:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
}

@test "every static suite is reachable from --fast" {
    # --fast runs the static tier, selected by directory rather than by a
    # second maintained list. A static suite the fast path skipped would go
    # stale without anything failing.
    local listed actual missing=""
    listed="$(bash "${BATS_TEST_DIRNAME}/../run.sh" --list --fast | cut -d: -f2- | sort)"
    actual="$(cd "${BATS_TEST_DIRNAME}/.." && ls static/*.bats \
        | sed 's|^|tests/|' | sort)"
    [ -n "$actual" ] || {
        echo "found no static suites to check; the glob is wrong" >&2
        return 1
    }
    [ "$listed" = "$actual" ] || {
        echo "--fast does not cover tests/static:" >&2
        diff <(printf '%s\n' "$actual") <(printf '%s\n' "$listed") >&2 || true
        return 1
    }
}

@test "run.sh invokes bats exactly once, inside run_suite" {
    # The dependency check names bats but must not execute it; if a second
    # invocation site ever appears, those suites would bypass the timing record.
    run grep -cE '^[[:space:]]*bats -T --formatter tap' "${BATS_TEST_DIRNAME}/../run.sh"
    [ "$output" -eq 1 ]
}

@test "run.sh prints a machine-readable result block" {
    # tests/run-wsl.sh reads these counts rather than re-deriving them, so a
    # rename here would silently break the wrapper's summary. tests_total is
    # what makes passed + failed + skipped checkable against the sum.
    local key
    for key in run_mode suites_total suites_passed suites_failed \
               tests_total tests_passed tests_failed tests_skipped; do
        assert_file_contains "${BATS_TEST_DIRNAME}/../run.sh" "echo \"${key}="
    done
}

@test "run.sh does not report a skipped test as passed" {
    # bats prints `ok 3 # skip reason` for a skip, so grepping '^ok ' counts
    # skipped tests as passed and the tally claims a test ran that never did.
    # configs.bats always has skip lines when the optional tools are absent.
    local run_sh="${BATS_TEST_DIRNAME}/../run.sh"
    assert_file_contains "$run_sh" "passed_count=\$((ok_count - skip_count))"
    # Skips are only ever reported on ok lines, so scope the count that way.
    assert_file_contains "$run_sh" "grep -c '^ok .*# skip'"
}

@test "run.sh's per-suite in-test total includes skipped tests" {
    # bats appends the skip reason after the timing:
    #   ok 3 a test in 941ms # skip no shellcheck here
    # An end-anchored match on the unstripped line drops those milliseconds,
    # so the suite reports less in-test time than the sum of its own tests.
    #
    # The skipped test sleeps first, so its measured body time is a round
    # second. run.sh prints the total to one decimal place, which cannot
    # distinguish 151ms from 215ms on the real suite; a whole second is
    # unambiguous either way.
    #
    # The suite is written to the test's temp directory, not to tests/, so the
    # checks that assert the repository's suite list is complete do not see it.
    local dir="${BATS_TEST_TMPDIR}/timing4"
    local suite="${BATS_TEST_TMPDIR}/skipped-time.bats"
    cat > "$suite" <<'BATS'
@test "a slow test that then skips" {
    sleep 1
    skip "no tool for this host"
}
BATS

    run env TIMING_DIR="$dir" \
        bash "${BATS_TEST_DIRNAME}/../run.sh" "$suite"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -qE 'skipped-time +ok +0 passed, 1 skipped' || {
        echo "the synthetic suite was not counted as a skip:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    # The summary line ends in the in-test total, e.g. "1.0s in tests".
    local reported
    reported="$(printf '%s\n' "$output" | grep -E '^  skipped-time ' \
        | grep -oE '[0-9]+\.[0-9]+s in tests' | grep -oE '^[0-9.]+' \
        | awk '{ printf "%d\n", $1 * 1000 }')"
    [ -n "$reported" ] || {
        echo "could not read the per-suite in-test total from:" >&2
        printf '%s\n' "$output" >&2
        return 1
    }
    [ "$reported" -ge 900 ] || {
        echo "run.sh reported ${reported}ms in tests; the skipped test alone took ~1000ms" >&2
        return 1
    }
}

@test "run.sh's result block counts every test exactly once" {
    # The sum invariant: passed + failed + skipped must equal the total. bats
    # reports a skip as `ok N # skip`, so a tally built from '^ok ' claims a
    # test passed that never ran, and the sum comes out over the total.
    #
    # TIMING_DIR is redirected so the nested run does not append to the outer
    # run's records.
    run env TIMING_DIR="${BATS_TEST_TMPDIR}/timing" \
        bash "${BATS_TEST_DIRNAME}/../run.sh" tests/static/configs.bats
    [ "$status" -eq 0 ] || {
        echo "run.sh failed on configs.bats:" >&2
        echo "$output" >&2
        return 1
    }
    local total passed failed skipped
    total="$(printf '%s\n' "$output" | sed -n 's/^tests_total=//p' | tail -1)"
    passed="$(printf '%s\n' "$output" | sed -n 's/^tests_passed=//p' | tail -1)"
    failed="$(printf '%s\n' "$output" | sed -n 's/^tests_failed=//p' | tail -1)"
    skipped="$(printf '%s\n' "$output" | sed -n 's/^tests_skipped=//p' | tail -1)"
    [ -n "$total" ] || {
        echo "no result block in run.sh output:" >&2
        echo "$output" >&2
        return 1
    }
    [ "$((passed + failed + skipped))" -eq "$total" ] || {
        echo "tally does not add up: ${passed}+${failed}+${skipped} != ${total}" >&2
        return 1
    }
    [ "$skipped" -eq "$total" ] && {
        echo "configs.bats skipped every test; the tally was not really exercised" >&2
        return 1
    }
    [ "$passed" -gt 0 ] || {
        echo "expected configs.bats to have some non-skipped tests" >&2
        return 1
    }
}

@test "run.sh reports the same test total the suite produced" {
    # Cross-check the block against the timing record, which is parsed
    # independently of the counters in run_suite. Two different derivations
    # of the same run agreeing is what makes the block trustworthy to the
    # wrapper.
    #
    # The rows land in last.tsv, not current.tsv: finalize moves the finished
    # run aside and resets the accumulating file for the next run.
    local dir="${BATS_TEST_TMPDIR}/timing2"
    run env TIMING_DIR="$dir" \
        bash "${BATS_TEST_DIRNAME}/../run.sh" tests/static/configs.bats
    [ "$status" -eq 0 ]
    local total recorded
    total="$(printf '%s\n' "$output" | sed -n 's/^tests_total=//p' | tail -1)"
    recorded="$(wc -l < "${dir}/last.tsv" | tr -d ' ')"
    [ "$recorded" -eq "$total" ] || {
        echo "run.sh says $total tests, timing.sh recorded $recorded" >&2
        return 1
    }
    [ ! -s "${dir}/current.tsv" ] || {
        echo "current.tsv was not reset for the next run" >&2
        return 1
    }
}

@test "run.sh accepts individual test files as arguments" {
    # The wrapper passes named suites through, so run.sh has to honour them.
    local f="${BATS_TEST_DIRNAME}/../run.sh"
    assert_file_contains "$f" 'FILES+=("$arg")'
    assert_file_contains "$f" 'MODE: $RUN_LABEL'
    # Explicit files win over --fast: the caller named something specific.
    assert_file_contains "$f" 'if [ "${#FILES[@]}" -gt 0 ]; then'
}

@test "run.sh has a help path listing its usage" {
    run bash "${BATS_TEST_DIRNAME}/../run.sh" --help
    [ "$status" -eq 0 ]
    assert_contains "$output" '--fast'
    assert_contains "$output" 'tests/unit/gpu-detect.bats'
}

@test "run.sh rejects a test file that does not exist" {
    run bash "${BATS_TEST_DIRNAME}/../run.sh" "tests/unit/definitely-absent.bats"
    [ "$status" -ne 0 ]
    assert_contains "$output" "no such test file"
}

@test "run.sh rejects an unknown option" {
    run bash "${BATS_TEST_DIRNAME}/../run.sh" --not-a-real-option
    [ "$status" -ne 0 ]
    assert_contains "$output" "unknown option"
}

@test "the WSL wrapper is syntactically valid" {
    run bash -n "${BATS_TEST_DIRNAME}/../run-wsl.sh"
    [ "$status" -eq 0 ]
}

@test "the WSL setup script is syntactically valid" {
    run bash -n "${BATS_TEST_DIRNAME}/../wsl-setup.sh"
    [ "$status" -eq 0 ]
}

@test "the WSL wrapper documents how to run the whole suite and named files" {
    local f="${BATS_TEST_DIRNAME}/../run-wsl.sh"
    assert_file_contains "$f" 'tests/run-wsl.sh                                  # whole suite'
    assert_file_contains "$f" 'tests/run-wsl.sh tests/unit/gpu-detect.bats'
    assert_file_contains "$f" 'bash tests/run-wsl.sh --setup'
}

@test "the WSL wrapper translates paths with forward slashes" {
    # wsl.exe passes the path through the Windows command line, where
    # backslashes are eaten as escapes: `C:\Users\x` arrives as `C:Usersx`.
    # Assert the wrapper uses cygpath -m, which emits forward slashes.
    run grep -c 'cygpath -m' "${BATS_TEST_DIRNAME}/../run-wsl.sh"
    [ "$output" -ge 1 ]
    run grep -c 'cygpath -w' "${BATS_TEST_DIRNAME}/../run-wsl.sh"
    [ "$output" -eq 0 ]
}

@test "the WSL wrapper puts the user bin directory on PATH" {
    # A non-interactive, non-login shell does not read ~/.bashrc, so the wrapper
    # has to pass the extended PATH explicitly or bats and shellcheck vanish.
    assert_file_contains "${BATS_TEST_DIRNAME}/../run-wsl.sh" 'run_path="$wsl_home/bin:$wsl_path"'
    assert_file_contains "${BATS_TEST_DIRNAME}/../run-wsl.sh" 'env PATH="$run_path"'
}

@test "the WSL wrapper refuses Windows tools reached over the drive mount" {
    local f="${BATS_TEST_DIRNAME}/../run-wsl.sh"
    assert_file_contains "$f" 'windows-tool:'
    assert_file_contains "$f" 'run-wsl.sh --setup'
}

@test "AGENTS.md tells agents to run the suite through the WSL wrapper" {
    local f="${BATS_TEST_DIRNAME}/../../AGENTS.md"
    [ -f "$f" ] || {
        echo "AGENTS.md is missing" >&2
        return 1
    }
    assert_file_contains "$f" 'tests/run-wsl.sh'
    assert_file_contains "$f" 'run.sh'
    assert_file_contains "$f" 'timing.sh'
}

@test "the docs declare no test counts" {
    # A count of the existing tests is a claim that goes stale on the very next
    # commit that adds one, and a stale count in documentation reads as truth.
    # The suite's own size is available from `tests/run.sh`; the docs should not
    # duplicate it.
    local root="${BATS_TEST_DIRNAME}/../.." f
    for f in "$root/AGENTS.md" "$root/specs/09-test-automation.md"; do
        if grep -nE 'Totals:|\*\*[0-9]+ tests|[0-9]+ tests\*\*|across [0-9]+ files' "$f"; then
            echo "$(basename "$f") states a test count; remove it" >&2
            return 1
        fi
    done
}

@test "the docs compare MSYS and WSL by ratio, not by measurement" {
    # Wall-clock figures for this repository on one workstation are not
    # transferable: they depend on the machine, the filesystem and the suite's
    # size at the time. The durable statement is the multiplier.
    local f="${BATS_TEST_DIRNAME}/../../AGENTS.md"
    # A table cell carrying a duration, e.g. "| WSL2, repo on /mnt/c | 13s |".
    if grep -nE '^\|.*\| *[0-9]+ *(s|ms|min) *\|' "$f"; then
        echo "AGENTS.md reports a wall-clock measurement; state the ratio instead" >&2
        return 1
    fi
    assert_file_contains "$f" 'orders of magnitude'
}

@test "timing records are excluded from version control" {
    run git -C "${BATS_TEST_DIRNAME}/../.." check-ignore tests/.timing/current.tsv
    [ "$status" -eq 0 ]
}

@test "the shared test helper library exists and is not ignored" {
    # Regression guard for an unanchored `lib/` rule in .gitignore, which
    # matched tests/lib/ and excluded the file every test file loads. A fresh
    # clone would then be unable to run any test.
    #
    # This asserts "not ignored", not "committed": whether the file is staged
    # is a property of the working tree, not of the ignore rules.
    [ -f "${BATS_TEST_DIRNAME}/../lib/helpers.bash" ]
    run git -C "${BATS_TEST_DIRNAME}/../.." check-ignore tests/lib/helpers.bash
    [ "$status" -ne 0 ]
}
