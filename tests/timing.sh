#!/usr/bin/env bash
# tests/timing.sh — record and report per-test execution time.
#
# Every bats invocation is asked for timing (`bats -T --formatter tap`), which
# annotates each result line with the time spent *inside* the test:
#
#     ok 1 a passing test in 632ms
#     not ok 2 a failing test in 679ms
#     ok 3 a skipped test in 941ms # skip no shellcheck here
#
# This script parses those lines into a tab-separated record, appends the run to
# a persistent history so slow tests can be tracked over time, and prints a
# report that separates the two costs that make a run slow:
#
#     work    - time inside test bodies, the part tests actually control
#     harness - wall time NOT attributed to a test body: bats' own per-test
#               process setup plus the fixed startup of each bats process
#
# The harness column is why a 3-test file can take 17s while its tests report
# 2.1s combined. On Windows/MSYS, where spawning a process costs ~65ms, that
# overhead dominates and optimizing individual tests has almost no effect. The
# report makes the split explicit so the effort goes where the time is.
#
# Usage:
#   tests/timing.sh parse <suite> <tap-file> <wall-ms>
#   tests/timing.sh finalize <label> <exit-rc>
#   tests/timing.sh report [--slowest N] [--regression-pct P]
#   tests/timing.sh history [--runs N]
#
# Environment:
#   TIMING_DIR            where records are kept (default: tests/.timing)
#   TIMING_SLOWEST        rows in the slowest-test table (default: 10)
#   TIMING_REGRESSION_PCT slowdown % that counts as a regression (default: 50)
#   TIMING_KEEP_RUNS      runs retained in history.tsv (default: 50)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMING_DIR="${TIMING_DIR:-${SCRIPT_DIR}/.timing}"
TIMING_SLOWEST="${TIMING_SLOWEST:-10}"
TIMING_REGRESSION_PCT="${TIMING_REGRESSION_PCT:-50}"
TIMING_REGRESSION_MIN_MS="${TIMING_REGRESSION_MIN_MS:-100}"
TIMING_KEEP_RUNS="${TIMING_KEEP_RUNS:-50}"

TAB=$'\t'
# Column order keeps the sortable numeric fields ahead of the test name, which
# may contain spaces and tabs' lookalikes.
#   suite \t num \t status \t ms \t wall_ms \t name
CURRENT="${TIMING_DIR}/current.tsv"
LAST="${TIMING_DIR}/last.tsv"
PREVIOUS="${TIMING_DIR}/previous.tsv"
HISTORY="${TIMING_DIR}/history.tsv"
RUNS="${TIMING_DIR}/runs.tsv"

log() {
    printf '%s\n' "$*"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ensure_dir() {
    mkdir -p "$TIMING_DIR"
}

now_ms() {
    # Date is a process spawn on MSYS (~65ms), so callers pass the epoch in
    # when they already have it. Fall back to a second-resolution estimate.
    local t
    t="$(date +%s%N 2>/dev/null || echo "")"
    if [ -n "$t" ] && [ "${t#*N}" = "$t" ]; then
        printf '%s' "$((t / 1000000))"
    else
        printf '%s' "$(( $(date +%s) * 1000 ))"
    fi
}

# parse <suite> <tap-file> <wall-ms>
# Extracts one row per test result and appends them to the current run.
parse() {
    local suite="$1" tap_file="$2" wall_ms="$3"
    [ -f "$tap_file" ] || die "timing: no such TAP file: $tap_file"
    ensure_dir
    [ -f "$CURRENT" ] || : > "$CURRENT"

    local line rest name ms status num
    while IFS= read -r line || [ -n "$line" ]; do
        # Ignore the plan line and bats' failure diagnostics, which are comments.
        case "$line" in
            '#'*|'1..'*) continue ;;
        esac

        # "ok 4 name" / "not ok 2 name"
        if [[ "$line" =~ ^(not\ ok|ok)[[:space:]]+([0-9]+)[[:space:]]+(.*)$ ]]; then
            status="${BASH_REMATCH[1]}"
            num="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[3]}"
        else
            continue
        fi

        # bats appends the skip reason AFTER the timing, as in
        #   ok 3 a test in 941ms # skip no shellcheck here
        # so the skip marker has to come off first; leaving it in place would
        # hide the timing suffix from the end-anchored match below and silently
        # discard the measurement.
        case "$rest" in
            *'# skip'*)
                status="skip"
                rest="${rest%%# skip*}"
                ;;
        esac

        # Trim the trailing whitespace the skip strip leaves behind.
        rest="${rest%"${rest##*[![:space:]]}"}"

        # Timing is the last field, so match it anchored to end-of-line. A greedy
        # leading group takes the *final* " in <n>ms", which keeps a test whose
        # own name ends in something like "in 42ms" intact.
        if [[ "$rest" =~ ^(.*)[[:space:]]in[[:space:]]([0-9]+)ms$ ]]; then
            name="${BASH_REMATCH[1]}"
            ms="${BASH_REMATCH[2]}"
        else
            # No timing: bats emits these for file-level errors such as
            # "bats-gather-tests". Record the test, but as unmeasured.
            name="$rest"
            ms=""
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$suite" "$num" "$status" "$ms" "$wall_ms" "$name" >> "$CURRENT"
    done < "$tap_file"
}

# summarize <tsv> — totals for one record file.
# Emits: tests counted ok failed skipped measured total_test_ms total_wall_ms
#
# total_wall_ms is the sum of the per-suite wall times, not the largest single
# one. Each suite's wall is recorded on every one of its rows, so the per-suite
# value is its maximum; summing those maxima is the only figure comparable with
# total_test_ms. Using the global maximum instead would produce a wall total
# smaller than the test total and a nonsensical negative harness figure.
summarize() {
    local tsv="$1"
    awk -F'\t' '
        NF >= 5 {
            tests++
            if ($3 == "ok")     { ok++ }
            if ($3 == "not ok") { failed++ }
            if ($3 == "skip")   { skipped++ }
            if ($4 != "") { measured++; test_ms += $4 }
            if ($5 != "") {
                if (!(($1) in seen) || $5 > wall[$1]) { wall[$1] = $5 }
                seen[$1] = 1
            }
        }
        END {
            for (s in wall) { total_wall += wall[s] }
            printf "%d %d %d %d %d %d %d\n",
                   tests + 0, ok + 0, failed + 0, skipped + 0,
                   measured + 0, test_ms + 0, total_wall + 0
        }
    ' "$tsv"
}

# overhead_by_suite <tsv> — the actionable table.
# For each suite: wall time vs time inside tests, and the unattributed remainder.
overhead_by_suite() {
    local tsv="$1"
    awk -F'\t' '
        NF >= 5 {
            s = $1
            if (!(s in seen)) { order[++n] = s; seen[s] = 1 }
            if ($4 != "") { sum[s] += $4 }
            if ($5 != "" && $5 > wall[s]) { wall[s] = $5 }
            count[s]++
        }
        END {
            for (i = 1; i <= n; i++) {
                s = order[i]
                w = wall[s] + 0
                t = sum[s] + 0
                o = w - t
                pct = (w > 0) ? (o * 100 / w) : 0
                printf "%s\t%d\t%d\t%d\t%.0f\n", s, count[s], w, t, pct
            }
        }
    ' "$tsv" | sort -t"$TAB" -k5,5nr
}

# slowest_tests <tsv> <n>
slowest_tests() {
    local tsv="$1" n="${2:-$TIMING_SLOWEST}"
    [ -s "$tsv" ] || return 0
    # Only measured rows: an unmeasured test is not "slow", it is unrecorded.
    awk -F'\t' 'NF >= 5 && $4 != ""' "$tsv" \
        | sort -t"$TAB" -k4,4nr \
        | head -n "$n"
}

# regressions <prev-tsv> <cur-tsv> <pct> [min-ms]
# Compares by suite+name so a test is tracked even if its number shifts.
#
# A percentage alone is not a usable signal for a suite where most tests finish
# in under 20ms: ordinary jitter turns 9ms into 16ms and reports it as a 70%
# regression. Requiring a minimum absolute increase as well keeps the report to
# slowdowns worth acting on.
regressions() {
    local prev="$1" cur="$2" pct="${3:-$TIMING_REGRESSION_PCT}"
    local min_ms="${4:-$TIMING_REGRESSION_MIN_MS}"
    [ -s "$prev" ] || return 0
    [ -s "$cur" ] || return 0
    awk -F'\t' -v pct="$pct" -v minms="$min_ms" '
        function key(suite, name) { return suite SUBSEP name }
        NR == FNR {
            if (NF >= 5 && $4 != "") { t[key($1, $6)] = $4 }
            next
        }
        NF >= 5 && $4 != "" {
            k = key($1, $6)
            if (k in t) {
                before = t[k] + 0
                after = $4 + 0
                grew = after - before
                # Floor the base too, so a 2ms -> 9ms change is not a 350%
                # regression.
                base = (before > 10) ? before : 10
                delta = grew * 100 / base
                if (grew >= minms && delta >= pct) {
                    printf "%s\t%s\t%d\t%d\t%.0f\t%s\n",
                           $1, $6, before, after, delta, $3
                }
            }
        }
    ' "$prev" "$cur" | sort -t"$TAB" -k5,5nr
}

# finalize <label> <exit-rc>
# Closes the current run: rotates the previous record, appends to history,
# prints the report, and records the run summary.
finalize() {
    local label="${1:-run}" exit_rc="${2:-0}"
    ensure_dir
    [ -f "$CURRENT" ] || : > "$CURRENT"

    # Keep the outgoing run as "previous" for the next comparison, and keep the
    # one before that so a report can still be produced after a failed run.
    if [ -f "$LAST" ]; then
        cp "$LAST" "$PREVIOUS"
    fi
    cp "$CURRENT" "$LAST"
    : > "$CURRENT"

    local stamp run_id
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u)"
    run_id="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "$stamp")"

    # Append this run to the cross-run history, prefixed with the run id.
    if [ -s "$LAST" ]; then
        awk -F'\t' -v r="$run_id" 'NF >= 5 { print r "\t" $0 }' "$LAST" \
            >> "$HISTORY"
    fi

    read -r tests ok failed skipped measured test_ms wall_ms < <(summarize "$LAST")
    printf '%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n' \
        "$run_id" "$stamp" "$label" \
        "$tests" "$failed" "$skipped" "$wall_ms" "$test_ms" "$exit_rc" \
        >> "$RUNS"

    rotate_runs

    report --slowest "$TIMING_SLOWEST" --regression-pct "$TIMING_REGRESSION_PCT"
}

# Rotate runs.tsv and history.tsv to the most recent TIMING_KEEP_RUNS runs.
rotate_runs() {
    [ -f "$RUNS" ] || return 0
    local keep="$TIMING_KEEP_RUNS"
    [ "$keep" -gt 0 ] 2>/dev/null || keep=50
    local total
    total="$(wc -l < "$RUNS" | tr -d ' ')"
    if [ "$total" -gt "$keep" ]; then
        local drop=$((total - keep))
        tail -n "$keep" "$RUNS" > "${RUNS}.tmp"
        mv "${RUNS}.tmp" "$RUNS"
        # Drop history rows for the run ids that fell off the end.
        awk -F'\t' -v d="$drop" '
            NR > d { print }
        ' "$RUNS" > "${RUNS}.tmp"
        awk -F'\t' -v keep_ids="$RUNS" '
            NR == FNR { keep[$1] = 1; next }
            ($1 in keep) { print }
        ' "$RUNS" "$HISTORY" > "${HISTORY}.tmp"
        mv "${HISTORY}.tmp" "$HISTORY"
        rm -f "${RUNS}.tmp"
    fi
}

fmt_ms() {
    local ms="$1"
    if [ -z "$ms" ]; then
        printf 'unmeasured'
    elif [ "$ms" -ge 60000 ]; then
        printf '%dm%02ds' "$((ms / 60000))" "$(( (ms % 60000) / 1000 ))"
    elif [ "$ms" -ge 1000 ]; then
        printf '%d.%02ds' "$((ms / 1000))" "$(( (ms % 1000) / 10 ))"
    else
        printf '%dms' "$ms"
    fi
}

report() {
    local slowest="$TIMING_SLOWEST" pct="$TIMING_REGRESSION_PCT"
    local min_ms="$TIMING_REGRESSION_MIN_MS"
    while [ $# -gt 0 ]; do
        case "$1" in
            --slowest) slowest="$2"; shift 2 ;;
            --regression-pct) pct="$2"; shift 2 ;;
            --regression-min-ms) min_ms="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ ! -s "$LAST" ]; then
        log "no timing records in $TIMING_DIR"
        return 0
    fi

    local tests ok failed skipped measured test_ms wall_ms
    read -r tests ok failed skipped measured test_ms wall_ms < <(summarize "$LAST")

    local overhead=0 overhead_pct=0
    if [ "$wall_ms" -gt 0 ]; then
        overhead=$((wall_ms - test_ms))
        overhead_pct=$((overhead * 100 / wall_ms))
    fi

    log ""
    log "=== timing ==="
    log ""
    log "  tests      $tests  ($ok ok, $failed failed, $skipped skipped)"
    log "  wall       $(fmt_ms "$wall_ms")   sum of suite wall times"
    log "  in tests   $(fmt_ms "$test_ms")   time inside test bodies ($measured measured)"
    log "  harness    $(fmt_ms "$overhead")   ${overhead_pct}% unattributed to test bodies"
    log ""

    # The suite-level split is the actionable view: it shows whether time is in
    # the tests or in bats' per-test process setup.
    local any_suite=0
    local row suite cnt w t p
    while IFS="$TAB" read -r suite cnt w t p; do
        [ -n "$suite" ] || continue
        any_suite=1
        local o=$((w - t))
        printf '  %-22s %3s tests  wall %7s  in-test %7s  harness %7s (%s%%)\n' \
            "$suite" "$cnt" "$(fmt_ms "$w")" "$(fmt_ms "$t")" \
            "$(fmt_ms "$o")" "$p"
    done < <(overhead_by_suite "$LAST")
    if [ "$any_suite" -eq 0 ]; then
        log "  (no per-suite rows recorded)"
    fi

    log ""
    log "  slowest $slowest tests:"
    local any_slow=0
    # Field order matches the record: suite, num, status, ms, wall_ms, name.
    local n_suite n_num n_status n_ms n_wall n_name
    while IFS="$TAB" read -r n_suite n_num n_status n_ms n_wall n_name; do
        [ -n "$n_suite" ] || continue
        any_slow=1
        printf '    %7s  %-20s %s\n' "$(fmt_ms "$n_ms")" "$n_suite" "$n_name"
    done < <(slowest_tests "$LAST" "$slowest")
    if [ "$any_slow" -eq 0 ]; then
        log "    (no measured tests)"
    fi

    # Only compare when a full previous run exists: a partial or aborted run
    # would otherwise make every surviving test look like a regression.
    if [ -s "$PREVIOUS" ]; then
        local prev_wall
        read -r _ _ _ _ _ _ prev_wall < <(summarize "$PREVIOUS")
        local prev_tests
        read -r prev_tests _ _ _ _ _ _ < <(summarize "$PREVIOUS")
        local cur_tests="$tests"
        # Require the previous run to cover at least as many tests, otherwise it
        # is not comparable (e.g. a --fast run compared against a full run).
        if [ "$prev_tests" -ge "$cur_tests" ]; then
            log ""
            log "  changes vs previous run (>= ${pct}% and >= ${min_ms}ms slower):"
            local any_reg=0
            local r_suite r_name r_before r_after r_delta r_status
            while IFS="$TAB" read -r r_suite r_name r_before r_after r_delta r_status; do
                [ -n "$r_suite" ] || continue
                any_reg=1
                printf '    %-24s %s -> %s (+%s%%)\n' \
                    "$r_name" "$(fmt_ms "$r_before")" "$(fmt_ms "$r_after")" "$r_delta"
            done < <(regressions "$PREVIOUS" "$LAST" "$pct" "$min_ms")
            if [ "$any_reg" -eq 0 ]; then
                log "    none"
            fi
        else
            log ""
            log "  no comparison: previous run had $prev_tests tests, this run had $cur_tests"
        fi
    fi
    log ""
    log "  history: $RUNS (last $TIMING_KEEP_RUNS runs), $HISTORY"
    log ""
}

# history [--runs N] — one line per recorded run, newest first.
show_history() {
    local n=20
    if [ "${1:-}" = "--runs" ]; then
        n="${2:-20}"
    fi
    if [ ! -s "$RUNS" ]; then
        log "no run history in $TIMING_DIR"
        return 0
    fi
    log ""
    log "=== run history (last $n) ==="
    log ""
    local r_id r_stamp r_label r_tests r_failed r_skipped r_wall r_test r_rc
    while IFS="$TAB" read -r r_id r_stamp r_label r_tests r_failed r_skipped r_wall r_test r_rc; do
        [ -n "$r_id" ] || continue
        printf '  %s  %-14s %3s tests  %2s failed  %2s skipped  wall %7s  in-test %7s  rc=%s\n' \
            "$r_stamp" "$r_label" "$r_tests" "$r_failed" "$r_skipped" \
            "$(fmt_ms "$r_wall")" "$(fmt_ms "$r_test")" "$r_rc"
    done < <(tail -n "$n" "$RUNS" | tac)
    log ""
}

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-report}"
    shift || true
    case "$cmd" in
        parse)        parse "${1:?suite}" "${2:?tap-file}" "${3:?wall-ms}" ;;
        finalize)     finalize "${1:-run}" "${2:-0}" ;;
        report)       report "$@" ;;
        slowest)      slowest_tests "$LAST" "${1:-$TIMING_SLOWEST}" ;;
        regressions)  regressions "${PREVIOUS:-$LAST}" "$LAST" "${1:-$TIMING_REGRESSION_PCT}" "${2:-$TIMING_REGRESSION_MIN_MS}" ;;
        history)      show_history "$@" ;;
        -h|--help|help) usage ;;
        *) die "timing: unknown command '$cmd' (try --help)" ;;
    esac
}

main "$@"
