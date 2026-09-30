#!/usr/bin/env bash
# tests/run-wsl.sh — run the test suite inside WSL, from Windows.
#
# Why this exists: under git-bash/MSYS every process spawn costs about 65ms, so
# the 187-test suite takes roughly 15 minutes, most of it waiting on bats to
# fork. The same suite under WSL finishes in under 20 seconds. On a Linux or
# macOS host, use tests/run.sh directly — this wrapper is for Windows only.
#
# Usage:
#   tests/run-wsl.sh                                  # whole suite
#   tests/run-wsl.sh --fast                           # static only
#   tests/run-wsl.sh tests/unit/gpu-detect.bats       # one suite
#   tests/run-wsl.sh tests/unit/frag10-iommu.bats tests/unit/control-tools.bats
#   tests/run-wsl.sh --setup                          # install WSL test tooling
#   tests/run-wsl.sh --distro Ubuntu-24.04 --slowest 20
#
# Timing records are written to tests/.timing/ inside the repository, so runs
# accumulate a history that can be compared with tests/timing.sh report and
# tests/timing.sh history.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

DISTRO=""
SETUP=0
SLOWEST=10
FAST=""
FILES=()

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --distro)   DISTRO="${2:?--distro needs a name}"; shift 2 ;;
        --setup)    SETUP=1; shift ;;
        --slowest)  SLOWEST="${2:?--slowest needs a number}"; shift 2 ;;
        --fast)     FAST="--fast"; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
        -*)         die "unknown option: $1 (try --help)" ;;
        *)          FILES+=("$1"); shift ;;
    esac
done

# --- wsl.exe must exist ---
if ! command -v wsl.exe >/dev/null 2>&1; then
    die "wsl.exe not found. This wrapper is for Windows hosts; on Linux or macOS use tests/run.sh"
fi

# --- Pick a distro ---
if [ -z "$DISTRO" ]; then
    # Prefer a general-purpose distro. docker-desktop is WSL2 too, but it has no
    # user home to install tooling into, so it is never a usable test target.
    DISTRO="$(MSYS_NO_PATHCONV=1 wsl.exe -l -q 2>/dev/null \
        | tr -d '\000' \
        | tr -d '\r' \
        | grep -vE '^[[:space:]]*(docker-desktop|docker-desktop-data)?[[:space:]]*$' \
        | head -1 \
        | tr -d '[:space:]' || true)"
fi
[ -n "$DISTRO" ] || die "no usable WSL distro found. Install one with 'wsl --install -d Ubuntu', or pass --distro NAME"

# MSYS rewrites anything that looks like a path before wsl.exe sees it, which
# turns /mnt/c/... into C:/... and breaks the invocation. Every call below sets
# MSYS_NO_PATHCONV=1 for that reason.
wsl_run() {
    MSYS_NO_PATHCONV=1 wsl.exe -d "$DISTRO" -- "$@"
}

# wsl_env <var-name> — read one variable out of the distro.
wsl_env() {
    wsl_run bash -c "printf '%s' \"\$$1\"" 2>/dev/null | tr -d '\000' | tr -d '\r'
}

# to_wsl_path <msys-path> — the WSL form of a path.
#
# Uses cygpath -m and not -w on purpose: wsl.exe hands the path to the Linux
# command through the Windows command line, where backslashes are consumed as
# escapes, so `C:\Users\x` arrives as `C:Usersx` and wslpath cannot resolve it.
# Forward slashes survive intact. wslpath is still what decides the mount point,
# so a distro that automounts C: somewhere other than /mnt/c still works.
to_wsl_path() {
    local unix_path="$1" win_path out
    win_path="$(cygpath -m "$unix_path" 2>/dev/null || printf '%s' "$unix_path")"
    out="$(wsl_run wslpath -u "$win_path" 2>/dev/null | tr -d '\000' | tr -d '\r')"
    printf '%s' "$out"
}

# --- Setup mode ---
if [ "$SETUP" -eq 1 ]; then
    log "==> installing WSL test tooling in '$DISTRO' (no sudo required)"
    wsl_run bash "$(to_wsl_path "${SCRIPT_DIR}/wsl-setup.sh")"
    exit $?
fi

# --- Translate paths to their WSL form ---
# These are Linux paths, so existence has to be tested inside WSL. Checking them
# with the host's test -d/-f would ask the Windows side about /mnt/c/... and
# always get "no".
repo_unix="$(to_wsl_path "$REPO_DIR")"
[ -n "$repo_unix" ] || die "could not translate the repository path for WSL"
wsl_run test -d "$repo_unix" \
    || die "WSL cannot see the repository at '$repo_unix'"

# Where the Windows drive is mounted. Used below to spot tools that are really
# Windows binaries, since the mount point is not always /mnt/c.
win_mount="$(wsl_run wslpath -u 'C:/' 2>/dev/null | tr -d '\000' | tr -d '\r')"
win_mount="${win_mount%/}"
[ -n "$win_mount" ] || win_mount="/mnt/c"

# Accept a repo-relative name or an absolute MSYS/Windows path.
WSL_FILES=()
for f in "${FILES[@]:-}"; do
    [ -n "$f" ] || continue
    if wsl_run test -f "$repo_unix/$f"; then
        WSL_FILES+=("$repo_unix/$f")
    elif [ -f "$f" ]; then
        unix="$(to_wsl_path "$f")"
        [ -n "$unix" ] || die "could not translate path: $f"
        wsl_run test -f "$unix" || die "no such test file: $f"
        WSL_FILES+=("$unix")
    else
        die "no such test file: $f"
    fi
done

# --- Preflight inside WSL ---
# The distro's own PATH has to be extended with ~/bin, where wsl-setup.sh puts
# bats-core and shellcheck. It cannot be left to ~/.bashrc: this runs a
# non-interactive, non-login shell, which does not read it.
wsl_home="$(wsl_env HOME)"
wsl_path="$(wsl_env PATH)"
[ -n "$wsl_path" ] || wsl_path="/usr/local/bin:/usr/bin:/bin"
run_path="$wsl_home/bin:$wsl_path"

# A Windows bats or shellcheck reached over the drive mount would put us back on
# the slow path while appearing to work, so refuse that explicitly.
preflight="$(wsl_run env PATH="$run_path" bash -s -- "$win_mount" <<'PREFLIGHT' 2>/dev/null | tr -d '\000' | tr -d '\r'
set -u
win_mount="$1"
rc=0
for t in bats shellcheck python3 git; do
    p="$(command -v "$t" 2>/dev/null || true)"
    if [ -z "$p" ]; then
        echo "missing:$t"
        rc=1
    elif [ -n "$win_mount" ] && [ "${p#"$win_mount"/}" != "$p" ]; then
        echo "windows-tool:$t=$p"
        rc=1
    fi
done
exit "$rc"
PREFLIGHT
)" || true

if printf '%s' "$preflight" | grep -q '^missing:'; then
    log "ERROR: required tooling is missing inside the '$DISTRO' distro:"
    printf '%s\n' "$preflight" | grep '^missing:' | sed 's/^missing:/  - /'
    log ""
    log "Install it without sudo:"
    log "  bash tests/run-wsl.sh --setup"
    exit 1
fi
if printf '%s' "$preflight" | grep -q '^windows-tool:'; then
    log "ERROR: these resolve to Windows binaries over /mnt/c, which would be as"
    log "       slow as running the suite natively on Windows:"
    printf '%s\n' "$preflight" | grep '^windows-tool:' | sed 's/^windows-tool:/  - /'
    log ""
    log "Install the native versions:"
    log "  bash tests/run-wsl.sh --setup"
    exit 1
fi

# --- Run ---
log "=== nested_dev tests via WSL ==="
log "    distro: $DISTRO"
log "    repo:   $repo_unix"
if [ "${#WSL_FILES[@]}" -gt 0 ]; then
    for f in "${WSL_FILES[@]}"; do
        log "    suite:  ${f#"$repo_unix"/}"
    done
elif [ -n "$FAST" ]; then
    log "    suite:  static only (--fast)"
else
    log "    suite:  all (use --fast, or name files, to narrow it)"
fi
log ""

# TIMING_SLOWEST lets the caller ask for a longer table without a second run.
#
# The output is teed rather than captured, so the suite streams as it runs, and
# PIPESTATUS[0] still reports the real exit status. Reading it from a command
# substitution would not work: the substitution runs in a subshell, so
# PIPESTATUS describes that subshell, not the wsl.exe invocation.
RUN_LOG="$(mktemp "${TMPDIR:-/tmp}/nested-dev-wsl-XXXXXX")"
trap 'rm -f "$RUN_LOG"' EXIT

set +e
wsl_run env PATH="$run_path" TIMING_SLOWEST="$SLOWEST" \
    bash "$repo_unix/tests/run.sh" $FAST ${WSL_FILES+"${WSL_FILES[@]}"} 2>&1 \
    | tr -d '\000' \
    | tee "$RUN_LOG"
RC="${PIPESTATUS[0]}"
set -e

# --- Tally ---
# The === result === block that tests/run.sh prints is authoritative, so read the
# counts from it rather than re-deriving them from the human-readable output.
field() {
    sed -n "s/^$1=//p" "$RUN_LOG" | tail -1
}

suites_total="$(field suites_total)"
suites_passed="$(field suites_passed)"
suites_failed="$(field suites_failed)"
tests_total="$(field tests_total)"
tests_passed="$(field tests_passed)"
tests_failed="$(field tests_failed)"
tests_skipped="$(field tests_skipped)"
run_mode="$(field run_mode)"

if [ -z "$suites_total" ]; then
    # tests/run.sh never reached its result block: it died in the dependency
    # check, or the distro could not execute it at all.
    log "=== summary ==="
    log "  the suite did not report a result; see the output above"
    log ""
    exit "${RC:-1}"
fi

log ""
log "=== summary ==="
if [ "${suites_failed:-0}" -gt 0 ] || [ "${RC:-0}" -ne 0 ]; then
    log "  RESULT   FAILED   ${suites_failed}/${suites_total} suites failed"
else
    log "  RESULT   PASSED   ${suites_passed}/${suites_total} suites"
fi
log "  tests    ${tests_passed} passed, ${tests_failed} failed, ${tests_skipped} skipped  (${tests_total} total)"
log "  mode     ${run_mode}"
log ""

# Every test is in exactly one of the three buckets. A mismatch means the run's
# own tally is wrong, which is worth saying out loud rather than printing
# numbers that silently do not add up.
if [ -n "${tests_total:-}" ] \
    && [ "$((tests_passed + tests_failed + tests_skipped))" -ne "$tests_total" ]; then
    log "  warning: passed + failed + skipped != total; the tally above is inconsistent."
    log ""
fi
log "  timing:  bash tests/timing.sh report"
log "  history: bash tests/timing.sh history"
log "  slowest: bash tests/timing.sh slowest ${SLOWEST}"
log ""

if [ "${suites_failed:-0}" -gt 0 ] || [ "${RC:-0}" -ne 0 ]; then
    log "  failing suites are printed in full above, with the assertion output."
    log ""
fi

exit "${RC:-0}"
