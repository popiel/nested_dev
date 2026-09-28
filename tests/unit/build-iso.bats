#!/usr/bin/env bats
# tests/unit/build-iso.bats — test build-iso pure functions

load '../lib/helpers'

setup() {
    source "${PROJECT_ROOT}/provision/ubuntu-release.conf"
    source "${PROJECT_ROOT}/provision/host/build-iso.sh"
}

teardown() {
    cleanup_mocks
    [ -n "${MSYSTEM:-}" ] && unset MSYSTEM
    [ -n "${_SAVED_PATH:-}" ] && PATH="$_SAVED_PATH"
    unset _SAVED_PATH
    return 0
}

@test "ubuntu-release.conf sets UBUNTU_VERSION" {
    [ "$UBUNTU_VERSION" = "26.04" ]
}

@test "ubuntu-release.conf sets UBUNTU_BASE_URL" {
    [ "$UBUNTU_BASE_URL" = "https://releases.ubuntu.com/26.04" ]
}

@test "sed_escape escapes backslash" {
    run sed_escape 'foo\bar'
    [ "$output" = 'foo\\bar' ]
}

@test "sed_escape escapes dollar signs" {
    run sed_escape 'abc$123'
    [ "$output" = 'abc\$123' ]
}

@test "sed_escape escapes pipe characters" {
    run sed_escape 'foo|bar'
    [ "$output" = 'foo\|bar' ]
}

@test "sed_escape escapes ampersand" {
    run sed_escape 'foo&bar'
    [ "$output" = 'foo\&bar' ]
}

@test "sed_escape handles yescrypt hash" {
    local hash='$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW.gJAqoB0k7emCAu.0N4o.bCemMC'
    run sed_escape "$hash"
    assert_contains "$output" '\$y\$j9T'
    assert_contains "$output" '\$6Y5z'
}

@test "build-iso no longer auto-detects a target disk from the build machine" {
    # The ISO is built on one machine and installed on another. A /dev probe
    # here only ever sees the *builder's* disks, and that name then gets baked
    # into the answer file as if it were the target's.
    assert_not_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'detect_target_disk'
    assert_not_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" '/dev/sd?'
    assert_not_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" '/sys/block'
}

@test "target disk preference comes from personalization, not a hardcoded default" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'validate_target_disks()'
    assert_file_contains "${PROJECT_ROOT}/provision/personalization.sh" 'PERSONALIZATION_TARGET_DISKS='
    assert_file_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" 'disk-list = [__TARGET_DISKS__]'
}

@test "no function in build-iso.sh is defined but never called" {
    # Replaces three "function exists" greps. Existence proves nothing; this
    # catches the failure those tests missed in both directions — a call to a
    # function that was renamed away, and a helper left behind after its last
    # caller was deleted.
    local script="${PROJECT_ROOT}/provision/host/build-iso.sh"
    local fn orphans=()
    while read -r fn; do
        [ -n "$fn" ] || continue
        # Definition plus every call site; a name used only once is never called.
        local uses
        uses=$(grep -cE "(^|[^[:alnum:]_])${fn}([^[:alnum:]_]|$)" "$script" || true)
        if [ "$uses" -le 1 ]; then
            orphans+=("$fn")
        fi
    done < <(grep -oE '^[[:alnum:]_]+\(\)' "$script" | sed 's/()$//')
    if [ "${#orphans[@]}" -ne 0 ]; then
        printf 'defined but never called: %s\n' "${orphans[*]}" >&2
        return 1
    fi
}

# --- Git Bash (MSYS) path handling ---
# MSYS rewrites POSIX-looking args passed to native binaries like docker.exe,
# which silently breaks every bind mount. These lock in the opt-out.

@test "is_msys is false on a normal Linux shell" {
    unset MSYSTEM
    run is_msys
    [ "$status" -ne 0 ]
}

@test "is_msys is true when MSYSTEM is set and cygpath exists" {
    setup_mock_path
    create_mock "cygpath" 'true'
    MSYSTEM="MINGW64"
    run is_msys
    [ "$status" -eq 0 ]
}

@test "is_msys is false when MSYSTEM is set but cygpath is missing" {
    # Empty PATH guarantees `command -v cygpath` fails on any platform,
    # including hosts that genuinely have cygpath (Git Bash).
    _SAVED_PATH="$PATH"
    mkdir -p "${BATS_TMPDIR}/emptybin"
    MSYSTEM="MINGW64"
    PATH="${BATS_TMPDIR}/emptybin"
    run is_msys
    [ "$status" -ne 0 ]
}

@test "host_path passes the path through unchanged off MSYS" {
    unset MSYSTEM
    run host_path "/c/Users/someone/output/iso"
    [ "$output" = "/c/Users/someone/output/iso" ]
}

@test "host_path converts via cygpath -m on MSYS" {
    setup_mock_path
    cat > "${FIXTURES_DIR}/mock-bin/cygpath" <<'SCRIPT'
#!/bin/bash
# Emit the -m (mixed, forward-slash) form for the only path we pass.
[[ "$1" == "-m" ]] || exit 3
echo "C:/converted/${2##*/}"
SCRIPT
    chmod +x "${FIXTURES_DIR}/mock-bin/cygpath"
    MSYSTEM="MINGW64"
    run host_path "/c/Users/someone/output/iso"
    [ "$output" = "C:/converted/iso" ]
}

@test "docker bind mounts are built from host_path, not raw MSYS paths" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '-v "$(host_path "$ISO_DIR"):/iso:ro"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '-v "$(host_path "$WORK_DIR"):/work"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '-v "$(host_path "$OUTPUT_DIR"):/output"'
}

@test "no bare 'docker run' remains — all calls go through docker_noconv" {
    run grep -nE '^[[:space:]]*docker (run|build|image)' \
        "${PROJECT_ROOT}/provision/host/build-iso.sh"
    [ -z "$output" ]
}

# --- Fail-loud artifact verification ---
# The container assistant can exit 0 after printing its own errors, so the
# presence of the ISO is the only trustworthy success signal.

@test "sha256_of returns the digest of a real file" {
    local f="${BATS_TMPDIR}/hashme"
    printf 'nested_dev\n' > "$f"
    run sha256_of "$f"
    [ "$status" -eq 0 ]
    [ "$output" = "$(sha256sum "$f" | awk '{print $1}')" ]
}

@test "sha256_of fails on a missing file" {
    run sha256_of "${BATS_TMPDIR}/definitely-absent.iso"
    [ "$status" -ne 0 ]
    assert_contains "$output" "not found"
}

@test "sha256_of fails on an empty file" {
    local f="${BATS_TMPDIR}/empty.iso"
    : > "$f"
    run sha256_of "$f"
    [ "$status" -ne 0 ]
    assert_contains "$output" "empty"
}

@test "write_manifest records the resolved REF SHA" {
    local m="${BATS_TMPDIR}/MANIFEST"
    : > "$m"
    write_manifest "$m" "main" "abc123def456789012345678901234567890abcd" \
        "proxmox-ve_9.2-1.iso" "deadbeef" "proxmox-ve_9.2-1_auto.iso" \
        "cafebabe"         '["nvme0n1"]' "/keys/host_os_ed25519.pub"
    run cat "$m"
    assert_contains "$output" "REF: main"
    assert_contains "$output" "REF SHA: abc123def456789012345678901234567890abcd"
    assert_contains "$output" "Auto ISO SHA256: cafebabe"
    assert_contains "$output" "Target disk: [\"nvme0n1\"]"
    assert_not_contains "$output" "unknown"
}

@test "spec 01 forbids the late-commands section PVE does not support" {
    # The spec previously prescribed a section the PVE autoinstall schema does
    # not accept, which is how an invalid answer file survived review.
    #
    # Assert the requirement itself rather than one sentence's wording: matching
    # a literal phrase made this test fail purely because the spec was rewritten
    # to be behaviour-focused, even though the prohibition is still normative
    # (R-01.2.1) and still covered by acceptance A-01.4.
    local spec="${PROJECT_ROOT}/specs/01-host-pve-install-media.md"

    # The prohibition has to be stated as a prohibition, not just mentioned.
    assert_file_matches "$spec" 'no `late-commands`'

    # The first-boot requirement has to name the supported mechanism. The spec
    # expresses this through the answer file's own keys, which is where an
    # operator implementing it would look.
    assert_file_contains "$spec" 'first-boot.source'
    assert_file_contains "$spec" 'from-iso'
    assert_file_contains "$spec" 'from-url'

    # The acceptance criteria must still check the answer file against the
    # validator, which is what actually caught the bad section.
    assert_file_contains "$spec" 'A-01.4'
}

@test "write_manifest heredoc performs no artifact-dependent substitution" {
    # Every build fact must arrive pre-computed as an argument. If the heredoc
    # called sha256sum/basename itself, a failed build could still write a
    # manifest entry. $(date -Is) is the sole permitted substitution: a clock
    # read that cannot fail and reveals nothing about build success.
    run sed -n '/^write_manifest()/,/^}/p' \
        "${PROJECT_ROOT}/provision/host/build-iso.sh"
    assert_not_contains "$output" 'sha256sum'
    assert_not_contains "$output" 'basename'
    assert_not_contains "$output" 'sha256_of'
}

@test "build verifies the ISO before reporting success" {
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/build-iso.sh")
    # The manifest write must come after the artifact check.
    local check_line manifest_line
    check_line=$(printf '%s\n' "$src" | grep -n 'AUTO_ISO_SHA256=\$(sha256_of' | cut -d: -f1)
    manifest_line=$(printf '%s\n' "$src" | grep -n 'write_manifest "\$MANIFEST"' | cut -d: -f1)
    [ -n "$check_line" ]
    [ -n "$manifest_line" ]
    [ "$check_line" -lt "$manifest_line" ]
}

@test "build-iso.sh no longer hashes AUTO_ISO inline" {
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        'sha256sum "\$AUTO_ISO"'
}

@test "build-iso.sh no longer falls back to an unset REF_SHA" {
    # The old manifest printed ${REF_SHA:-unknown} while REF_SHA was never
    # assigned, so every build recorded "unknown" and looked unpinned.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        'REF_SHA:-unknown'
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        'resolve_ref_to_sha'
}

@test "resolve_ref_to_sha is available from personalization.sh" {
    source "${PROJECT_ROOT}/provision/personalization.sh"
    declare -F resolve_ref_to_sha >/dev/null
}

# --- Assistant exit-code unreliability ---
# proxmox-auto-install-assistant exits 0 even on a hard parse error, so its
# output has to be inspected.

@test "assistant_reports_error detects a leading Error: line" {
    run assistant_reports_error 'Error parsing answer file: TOML parse error'
    [ "$status" -eq 0 ]
}

@test "assistant_reports_error detects the summary error line" {
    run assistant_reports_error 'Error: Found issues in the answer file.'
    [ "$status" -eq 0 ]
}

@test "assistant_reports_error is quiet on success output" {
    run assistant_reports_error 'Checking provided answer file...'
    [ "$status" -ne 0 ]
}

@test "run_assistant_checked dies when the command reports an error but exits 0" {
    # The exact failure mode: exit status 0, message on stdout.
    run run_assistant_checked "schema check" bash -c 'echo "Error: boom"; exit 0'
    [ "$status" -ne 0 ]
    assert_contains "$output" "schema check"
}

@test "run_assistant_checked dies on a non-zero status" {
    run run_assistant_checked "schema check" bash -c 'exit 3'
    [ "$status" -ne 0 ]
    assert_contains "$output" "exit 3"
}

@test "run_assistant_checked passes through clean output" {
    run run_assistant_checked "schema check" bash -c 'echo "all good"'
    [ "$status" -eq 0 ]
    assert_contains "$output" "all good"
}

@test "run_assistant_checked is not used for prepare-iso" {
    # prepare-iso legitimately prints progress that may contain the word
    # "error"; its success signal is the ISO itself, checked via sha256_of.
    run grep -n 'run_assistant_checked' "${PROJECT_ROOT}/provision/host/build-iso.sh"
    assert_not_contains "$output" "prepare-iso"
}

# --- Template rendering ---
# These are behavioural, not just existence checks. A parameter-order slip in
# render_template once wrote the answer file to a path named after the SSH key,
# leaving a stale template to be validated and built with.
#
# render_template takes two separate hashes (root, then personalization) before
# the destination, because they come from two different files and go to two
# different systems. setup_personalization() is sourced by every rendering test
# so the identity placeholders have something to substitute; without it they
# survive into the output and trip the build's own placeholder guard.

setup_personalization() {
    PERSONALIZATION_EMAIL="someone@example.com"
    PERSONALIZATION_USERNAME="testuser"
    PERSONALIZATION_FULLNAME="Test User"
    PERSONALIZATION_UID="1401"
    PERSONALIZATION_GID="1401"
    PERSONALIZATION_HOME="/home/testuser"
}

@test "render_template writes to the destination argument" {
    # Regression: the renderer once appended to $OUT instead of honouring the
    # destination it was handed, so every caller's output went missing. The
    # substituted values themselves are covered by the two tests below.
    local out="${BATS_TMPDIR}/rendered.toml"
    setup_personalization
    run generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "nvme0n1" "ssh-ed25519 AAAA" "v1.2" '$y$j9T$abc$def' 'PERSONAL_HASH' "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
}

@test "render_template substitutes every placeholder and leaves none behind" {
    # Runs over the answer file and the host bootstrap together. The bootstrap
    # was previously untested for leftovers: the old tests/unit/template.bats
    # re-implemented the sed pipeline inline instead of calling this function,
    # so it proved sed works, not that the shipped bootstrap is complete. An
    # unsubstituted token here reaches a headless host with no console to
    # report it.
    local out="${BATS_TMPDIR}/rendered2.toml"
    local boot="${BATS_TMPDIR}/rendered2-first-boot.sh"
    setup_personalization
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" 'HASH' 'PERSONAL_HASH' "$out"
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "ssh-ed25519 AAAAsomenoise" "main" 'ROOTHASH' 'PERSONALHASH' "$boot"
    local rendered
    for rendered in "$out" "$boot"; do
        run grep -o '__[A-Z_][A-Z_]*__' "$rendered"
        if [ -n "$output" ]; then
            echo "unsubstituted placeholders left in ${rendered}:" >&2
            echo "$output" >&2
            return 1
        fi
    done
}

@test "render_template escapes a yescrypt hash so sed survives it" {
    # An unescaped $y$j9T$... would expand to nothing and silently blank the
    # root password, producing an install with no working credentials.
    local out="${BATS_TMPDIR}/rendered3.toml"
    setup_personalization
    local hash='$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" "$hash" 'PERSONAL_HASH' "$out"
    run cat "$out"
    assert_contains "$output" '$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
}

@test "render_template warns-by-placeholder when personalization is not sourced" {
    # The answer file carries only the email (plus the already-passed root
    # hash, key and ref); the rest of the identity rides the bootstrap, because
    # PVE's schema has no non-root user field.
    local out="${BATS_TMPDIR}/rendered4.toml"
    unset PERSONALIZATION_EMAIL
    unset PERSONALIZATION_USERNAME
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" 'HASH' 'PERSONAL_HASH' "$out"
    # The placeholder survives, which is what the build's guard detects.
    run cat "$out"
    assert_contains "$output" '__PERSONALIZATION_EMAIL__'
    assert_not_contains "$output" '__PERSONALIZATION_USERNAME__'
}

@test "the bootstrap is where an unsourced identity shows up as a placeholder" {
    # The account name, UID, GID, home and shell have no answer-file field to
    # live in, so the bootstrap is the only template that can show a
    # surviving __PERSONALIZATION_*__ placeholder. Without this the host would
    # be created with the literal string "popiel" as a username.
    local boot="${BATS_TMPDIR}/rendered4-firstboot.sh"
    unset PERSONALIZATION_EMAIL
    unset PERSONALIZATION_USERNAME
    unset PERSONALIZATION_UID
    unset PERSONALIZATION_GID
    unset PERSONALIZATION_HOME
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "KEY" "main" 'HASH' 'PERSONAL_HASH' "$boot"
    run cat "$boot"
    assert_contains "$output" '__PERSONALIZATION_USERNAME__'
    assert_contains "$output" '__PERSONALIZATION_UID__'
    assert_contains "$output" '__PERSONALIZATION_GID__'
    assert_contains "$output" '__PERSONALIZATION_HOME__'
}

# --- Two hashes, two destinations ---
# keys/root-password-hash is the host root credential and must never appear in
# the first-boot bootstrap; keys/personalization-password-hash is the login
# password and must never become the host's root password. Swapping the two
# positionals in render_template would compile, validate and install, and hand
# out a host whose root password is the account's login password (or worse).

@test "the answer file receives the root hash and the bootstrap the login hash" {
    local answer="${BATS_TMPDIR}/split-answer.toml"
    local boot="${BATS_TMPDIR}/split-firstboot.sh"
    setup_personalization
    local root_hash='$y$j9T$ROOTONLY'
    local personal_hash='$y$j9T$PERSONALONLY'
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        '"sda"' "KEY" "main" "$root_hash" "$personal_hash" "$answer"
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "KEY" "main" "$root_hash" "$personal_hash" "$boot"
    run cat "$answer"
    assert_contains "$output" '$y$j9T$ROOTONLY'
    assert_not_contains "$output" '$y$j9T$PERSONALONLY'
    run cat "$boot"
    assert_contains "$output" '$y$j9T$PERSONALONLY'
    assert_not_contains "$output" '$y$j9T$ROOTONLY'
}

@test "render_template escapes the personalization hash too" {
    # Same trap as the root hash: an unescaped yescrypt string expands to
    # nothing, which would leave the host account without a working password.
    local boot="${BATS_TMPDIR}/escaped-personal.sh"
    setup_personalization
    local personal_hash='$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "KEY" "main" 'ROOTHASH' "$personal_hash" "$boot"
    run cat "$boot"
    assert_contains "$output" '$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
}

@test "render_template substitutes the personalization identity" {
    # The bootstrap creates the host account from these, and the first-boot
    # hook runs before provision/personalization.sh exists on the host.
    local boot="${BATS_TMPDIR}/identity.sh"
    setup_personalization
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "KEY" "main" 'ROOTHASH' 'PERSONALHASH' "$boot"
    run cat "$boot"
    assert_contains "$output" 'testuser'
    assert_contains "$output" 'Test User'
    assert_contains "$output" '1401'
    assert_contains "$output" '/home/testuser'
}

@test "render_template injects the operator key for the account's authorized_keys" {
    local boot="${BATS_TMPDIR}/pubkey.sh"
    setup_personalization
    generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        '"sda"' "ssh-ed25519 AAAAsomenoise" "main" 'ROOTHASH' 'PERSONALHASH' "$boot"
    run cat "$boot"
    assert_contains "$output" 'ssh-ed25519 AAAAsomenoise'
    run grep -c '__ADMIN_PUBKEY__' "$boot"
    [ "$output" = "0" ]
}

# --- Target disk preference ---
# The installer partitions the first disk-list entry that is present, so the
# list is a preference order AND a safety boundary: anything omitted can never
# be selected or wiped. These lock both properties down.

@test "validate_target_disks normalizes a list of quoted device names" {
    # Also the fail-safe guard: the build must not widen the list to a fallback,
    # so the output must be exactly the one entry that was asked for and no
    # other device name.
    run validate_target_disks '"nvme0n1"'
    [ "$status" -eq 0 ]
    [ "$output" = '"nvme0n1"' ]
    local tokens
    tokens=$(printf '%s\n' "$output" | grep -oE '"[^"]+"' | wc -l)
    [ "$tokens" -eq 1 ]
}

@test "validate_target_disks tolerates hand-edited whitespace" {
    run validate_target_disks ' "nvme0n1" '
    [ "$status" -eq 0 ]
    [ "$output" = '"nvme0n1"' ]
}

@test "validate_target_disks is idempotent when already bracketed" {
    run validate_target_disks '["nvme0n1"]'
    [ "$status" -eq 0 ]
    [ "$output" = '"nvme0n1"' ]
}

@test "validate_target_disks rejects more than one disk for ext4" {
    # PVE's schema allows exactly one disk for ext4/xfs; validate-answer fails
    # with "make sure to define only one disk for ext4 and xfs". Catch it here
    # so an ordered preference list is an actionable build error, not a schema
    # failure discovered after a 1.7 GB ISO build.
    run validate_target_disks '"nvme0n1", "sda"'
    [ "$status" -ne 0 ]
    assert_contains "$output" "lists 2 disks"
    assert_contains "$output" "ext4"
    assert_contains "$output" "Pin the single install target"
}

@test "validate_target_disks rejects an unset preference" {
    run validate_target_disks ''
    [ "$status" -ne 0 ]
    assert_contains "$output" "PERSONALIZATION_TARGET_DISKS is unset"
}

@test "validate_target_disks rejects an empty list" {
    run validate_target_disks '[]'
    [ "$status" -ne 0 ]
    assert_contains "$output" "is empty"
}

@test "validate_target_disks rejects a /dev path" {
    # PVE resolves these against /dev itself; a path silently never matches.
    run validate_target_disks '"/dev/nvme0n1"'
    [ "$status" -ne 0 ]
    assert_contains "$output" "bare device name"
}

@test "validate_target_disks rejects partition names" {
    # A partition is a silent mis-target rather than an obvious error.
    run validate_target_disks '"nvme0n1p1"'
    [ "$status" -ne 0 ]
    assert_contains "$output" "looks like a partition"
    run validate_target_disks '"sda1"'
    [ "$status" -ne 0 ]
    assert_contains "$output" "looks like a partition"
}

@test "validate_target_disks rejects an unquoted entry" {
    run validate_target_disks 'nvme0n1'
    [ "$status" -ne 0 ]
    assert_contains "$output" "must be quoted"
}

@test "validate_target_disks rejects an empty entry" {
    run validate_target_disks '"nvme0n1", '
    [ "$status" -ne 0 ]
    assert_contains "$output" "empty entry"
}

@test "render_template emits disk-list as a verbatim TOML array" {
    local out="${BATS_TMPDIR}/disks.toml"
    setup_personalization
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        '"nvme0n1"' "KEY" "main" 'HASH' 'PERSONAL_HASH' "$out"
    run grep -E '^disk-list' "$out"
    [ "$output" = 'disk-list = ["nvme0n1"]' ]
}

@test "answer-host.toml renders to valid TOML with a one-element disk-list" {
    # The template is only valid TOML once rendered, so assert the rendered form.
    local out="${BATS_TMPDIR}/disks-valid.toml"
    setup_personalization
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        '"nvme0n1"' "KEY" "main" 'HASH' 'PERSONAL_HASH' "$out"
    run python3 -c "import tomllib,sys; d=tomllib.load(open(r'$(win_path "$out")','rb')); sys.exit(0 if d['disk-setup']['disk-list']==['nvme0n1'] else 1)"
    [ "$status" -eq 0 ]
}

@test "generate_first_boot_script renders the bootstrap and marks it executable" {
    local out="${BATS_TMPDIR}/first-boot.sh"
    rm -f "$out"
    setup_personalization
    run generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        "sda" "KEY" "main" 'HASH' 'PERSONAL_HASH' "$out"
    [ "$status" -eq 0 ]
    [ -x "$out" ]
    run cat "$out"
    assert_contains "$output" 'HASH'
    assert_contains "$output" 'main'
}

@test "answer-host.toml has no late-commands section" {
    # PVE's autoinstall schema has no such section; it was silently invalid and
    # only surfaced once the file was actually readable by the assistant.
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        'late-commands'
}

@test "answer-host.toml first-boot uses from-iso, not from-url" {
    # from-url would require the password hash to be reachable over the
    # network; the bootstrap is embedded in the ISO instead.
    assert_file_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        'source = "from-iso"'
    assert_file_not_contains "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        'from-url'
}

@test "prepare-iso is given a writable --tmp" {
    # The assistant otherwise stages in the source ISO's directory, which is
    # mounted read-only at /iso and fails with "Read-only file system".
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--tmp /work'
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--tmp "$tmp_dir"'
}

@test "first-boot bootstrap is passed to prepare-iso in both carriers" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--on-first-boot "$first_boot"'
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--on-first-boot "/work/$(basename "$FIRST_BOOT_WORK")"'
}
