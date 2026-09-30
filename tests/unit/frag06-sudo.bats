#!/usr/bin/env bats
# tests/unit/frag06-sudo.bats — the sudo install branch, with sudo absent.
#
# The end-to-end suite runs on machines where sudo is already installed, so it
# only ever exercises frag/06's no-op branch. This file runs the fragment with
# an isolated PATH from which sudo is absent — the shape of the real host —
# and proves the install branch runs and its post-install verification
# observes the installed binary. The apt stub materializes each installed
# package as an executable, which is the observable effect of an install.

load '../lib/helpers'

FRAG06="${PROJECT_ROOT}/provision/host/frag/06-sudo.sh"
E2E_STUBS="${PROJECT_ROOT}/tests/e2e/stubs"

setup() {
    # mktemp, not BATS_TMPDIR: BATS_TMPDIR is shared across the tests in this
    # file, and the install branch appends to a journal whose absence another
    # test asserts. A shared directory turns test order into test state.
    WORK="$(mktemp -d)"
    MOCKBIN="${WORK}/mockbin"
    STATE="${WORK}/state"
    mkdir -p "$MOCKBIN" "$STATE"
    for stub in apt-get getent groupadd date; do
        cp "${E2E_STUBS}/${stub}" "$MOCKBIN/$stub"
    done
    # chmod is a pure filesystem utility, not system state: the apt stub needs
    # it to mark materialized packages executable, and the isolation here is
    # about sudo's absence, which chmod does not affect.
    cp "$(command -v chmod)" "$MOCKBIN/chmod"
    chmod +x "$MOCKBIN"/*
}

teardown() {
    rm -rf "$WORK"
}

run_frag06() {
    # Absolute bash: env -i clears PATH before resolving the interpreter, so a
    # bare `bash` would fail even though that failure is the harness's, not the
    # fragment's. /bin/bash is where Debian, PVE and Ubuntu all keep it.
    env -i PATH="$MOCKBIN" \
        PVE_ROOT="${WORK}/root" \
        E2E_STATE="$STATE" \
        E2E_MOCKBIN="$MOCKBIN" \
        /bin/bash "$FRAG06"
}

@test "the sudo package is installed when absent" {
    run run_frag06
    [ "$status" -eq 0 ]
    assert_file_contains "$STATE/apt-journal" "install -y sudo"
    # The install made the binary appear; the fragment's own verification saw it.
    [ -x "$MOCKBIN/sudo" ]
}

@test "an already-installed sudo is left alone" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/sudo"
    chmod +x "$MOCKBIN/sudo"
    run run_frag06
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/apt-journal" ] || {
        echo "apt was called despite sudo being present:" >&2
        cat "$STATE/apt-journal" >&2
        return 1
    }
}

@test "the sudo group is ensured even when the package was already present" {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/sudo"
    chmod +x "$MOCKBIN/sudo"
    # groupadd records into the account journal via a tiny shim. Absolute
    # interpreter, like the stubs: the isolated PATH has no bash for env.
    cat > "$MOCKBIN/groupadd" <<'EOF'
#!/bin/bash
printf 'groupadd %s\n' "$*" >> "${E2E_STATE:?}/account-journal"
exit 0
EOF
    chmod +x "$MOCKBIN/groupadd"
    run run_frag06
    [ "$status" -eq 0 ]
    assert_file_contains "$STATE/account-journal" "groupadd -r sudo"
}
