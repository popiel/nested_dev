#!/usr/bin/env bats
# tests/static/lint.bats — shellcheck all shell scripts

load '../lib/helpers'

# Covers: R-09.2.1
@test "shellcheck passes on all .sh scripts" {
    require_command shellcheck
    local fail=0
    for script in $(find "$PROJECT_ROOT" -name '*.sh' \
        -not -path '*/tests/*' \
        -not -path '*/output/*' \
        -not -path '*/.git/*'); do
        # SC1091: can't follow dynamic source paths (expected)
        # SC2034: unused variables in sourced config files (expected)
        # SC2016: intentional single quotes in echo (e.g. .bashrc PATH export)
        run shellcheck -x -s bash -e SC1091,SC2034,SC2016 "$script"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: $script" >&2
            echo "$output" >&2
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

# Covers: R-09.2.1, A-09.16
@test "shellcheck passes on the test harness scripts" {
    # The sweep above excludes tests/ wholesale, because .bats files are not
    # shell. These four are ordinary shell scripts, though, and nothing else
    # would ever look at them.
    require_command shellcheck
    local fail=0
    local script full_path
    for script in tests/run.sh tests/run-wsl.sh tests/timing.sh tests/wsl-setup.sh; do
        full_path="${PROJECT_ROOT}/${script}"
        [ -f "$full_path" ] || {
            echo "MISSING: $script" >&2
            fail=1
            continue
        }
        run shellcheck -x -s bash -e SC1091,SC2034,SC2016 "$full_path"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: $script" >&2
            echo "$output" >&2
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

# Covers: R-09.2.1
@test "shellcheck passes on extension-less bash scripts" {
    require_command shellcheck
    local fail=0
    for script in \
        dev/tools/nested \
        dev/tools/dev-refresh-images \
        provision/host/vmctl/vmctl-host; do
        full_path="${PROJECT_ROOT}/${script}"
        [ -f "$full_path" ] || continue
        head -1 "$full_path" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash' || continue
        run shellcheck -x -s bash -e SC1091,SC2034 "$full_path"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: $script" >&2
            echo "$output" >&2
            fail=1
        fi
    done
    [ "$fail" -eq 0 ]
}

# Covers: R-09.2.2
@test "every sourced-later script has a source-guard" {
    # A script without this guard runs main() the moment a test sources it, so
    # its functions are only unit-testable by accident and any future test that
    # sources one will start executing real host actions.
    local script guard='BASH_SOURCE\[0\].*==.*\$0'
    for script in \
        provision/host/build-iso.sh \
        provision/host/frag/10-gpu-passthrough.sh \
        provision/host/frag/30-create-guests.sh; do
        if ! assert_file_matches "${PROJECT_ROOT}/${script}" "$guard"; then
            return 1
        fi
    done
}

# Covers: R-01.3, R-09.2.1
@test "sh scripts parse under /bin/sh" {
    # first-boot.sh runs on a stock Debian PVE host where /bin/sh is dash, but
    # the lint tier only checked it with shellcheck -s bash. A bashism here
    # fails at provisioning time on the one host that matters, not in CI.
    require_command dash
    local script
    for script in \
        provision/host/first-boot.sh \
        provision/host/provision-host.sh; do
        run dash -n "${PROJECT_ROOT}/${script}"
        if [ "$status" -ne 0 ]; then
            echo "FAIL: ${script} does not parse as /bin/sh" >&2
            echo "$output" >&2
            return 1
        fi
    done
}

# Covers: R-09.1
@test "the CI entry point is executable in the git index" {
    # CI invokes tests/run.sh directly; without the exec bit that is
    # permission denied on a Linux runner. Undetectable by running the
    # suite: WSL's DrvFs presents every file as executable, and the
    # documented invocation (`bash tests/run.sh`) never checks the bit.
    # Only the git index tells the truth, so assert on it, not -x.
    require_command git
    local mode
    mode="$(git -C "$PROJECT_ROOT" ls-files -s -- tests/run.sh | cut -d' ' -f1)"
    [ "$mode" = "100755" ] || {
        echo "tests/run.sh mode in git index: ${mode:-untracked}" >&2
        return 1
    }
}

# Covers: R-09.4, I-09.5
@test "bash entry points are invoked with bash, never sh" {
    # /bin/sh is dash on Debian/PVE and dies on pipefail: two call sites ran
    # the bash provisioner under sh, green wherever sh happens to be bash,
    # red everywhere else (observed: dead e2e setup and dead refresh on CI).
    # Positive pins on both known sites.
    assert_file_contains "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '/bin/bash "${PROVISION_DIR}/host/provision-host.sh"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/refresh-provisioner.sh" \
        '/bin/bash "${PROVISION_DIR}/host/provision-host.sh"'
}

# Covers: R-09.1
@test "CI installs the pinned test tools, not apt builds" {
    # Apt's bats/shellcheck lag and differ in behavior (TAP error shapes,
    # findings), failing version-sensitive tests that pass locally
    # (observed: green suite, red CI). Parity comes from wsl-setup.sh;
    # pin its use and keep both tools off the apt line.
    local ci="${PROJECT_ROOT}/.github/workflows/ci.yml"
    assert_file_contains "$ci" 'bash tests/wsl-setup.sh'
    assert_file_contains "$ci" 'GITHUB_PATH'
    assert_file_not_contains "$ci" 'install -y bats'
    assert_file_not_contains "$ci" 'install -y shellcheck'
}

# Covers: R-09.6.2
@test "every test names the requirements it verifies" {
    # An unstated gap reads as a covered one: each @test carries a `# Covers:`
    # line naming the R-/A-/I- IDs it verifies, so the Spec 09 §4 coverage map
    # is checkable per test instead of per suite. Heredoc-embedded fixture
    # suites (timing.bats writes .bats files into $TMPDIR) are not real tests
    # and are skipped via heredoc tracking, mirroring the annotator.
    local file line heredoc prev fails=0
    for file in tests/static/*.bats tests/unit/*.bats tests/e2e/*.bats; do
        heredoc=""
        prev="# Covers: seed"
        while IFS= read -r line || [ -n "$line" ]; do
            if [ -n "$heredoc" ]; then
                [ "$line" = "$heredoc" ] && heredoc=""
                prev="$line"
                continue
            fi
            case "$line" in
                '@test "'*)
                    case "$prev" in
                        '# Covers: '*) ;;
                        *)
                            echo "UNANNOTATED: $file: $line" >&2
                            fails=1
                            ;;
                    esac
                    ;;
            esac
            if printf '%s' "$line" | grep -qE "<<['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?[[:space:]]*$"; then
                heredoc="$(printf '%s' "$line" | sed -E "s/.*<<['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[[:space:]]*$/\1/")"
            fi
            prev="$line"
        done < "${PROJECT_ROOT}/${file}"
    done
    [ "$fails" -eq 0 ]
}
