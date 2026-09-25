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

@test "detect_target_disk function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'detect_target_disk()'
}

@test "generate_answer_file function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'generate_answer_file()'
}

@test "run_prepare_iso function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'run_prepare_iso()'
}

@test "download_iso function exists in build-iso" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'download_iso()'
}

@test "build-iso.sh has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/build-iso.sh" 'BASH_SOURCE\[0\].*==.*\$0'
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
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '-v "$(host_path "$ISO_DIR"):/iso:ro"'
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '-v "$(host_path "$WORK_DIR"):/work"'
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
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
        "cafebabe" "nvme0n1" "/keys/host_os_ed25519.pub"
    run cat "$m"
    assert_contains "$output" "REF: main"
    assert_contains "$output" "REF SHA: abc123def456789012345678901234567890abcd"
    assert_contains "$output" "Auto ISO SHA256: cafebabe"
    assert_contains "$output" "Target disk: nvme0n1"
    assert_not_contains "$output" "unknown"
}

@test "spec 01 documents that late-commands does not exist" {
    # The spec previously prescribed a section the PVE tool rejects, which is
    # how the invalid answer file survived review.
    local spec="${PROJECT_ROOT}/specs/01-host-pve-install-media.md"
    assert_contains "$(cat "$spec")" 'No `late-commands`'
    assert_contains "$(cat "$spec")" '--on-first-boot'
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

@test "render_template writes to the destination argument" {
    local out="${BATS_TMPDIR}/rendered.toml"
    local hash='$y$j9T$abc$def'
    PERSONALIZATION_EMAIL="someone@example.com"
    run generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "nvme0n1" "ssh-ed25519 AAAA" "v1.2" "$hash" "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    run cat "$out"
    assert_contains "$output" 'nvme0n1'
    assert_contains "$output" 'ssh-ed25519 AAAA'
    assert_contains "$output" 'v1.2'
    assert_contains "$output" 'someone@example.com'
}

@test "render_template substitutes every placeholder and leaves none behind" {
    local out="${BATS_TMPDIR}/rendered2.toml"
    PERSONALIZATION_EMAIL="someone@example.com"
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" 'HASH' "$out"
    run grep -o '__[A-Z_][A-Z_]*__' "$out"
    [ -z "$output" ]
}

@test "render_template escapes a yescrypt hash so sed survives it" {
    # An unescaped $y$j9T$... would expand to nothing and silently blank the
    # root password, producing an install with no working credentials.
    local out="${BATS_TMPDIR}/rendered3.toml"
    PERSONALIZATION_EMAIL="someone@example.com"
    local hash='$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" "$hash" "$out"
    run cat "$out"
    assert_contains "$output" '$y$j9T$GSFbB5goTmV.aoKo5jISb/$6Y5zIG4SencKlWYW'
}

@test "render_template warns-by-placeholder when personalization is not sourced" {
    local out="${BATS_TMPDIR}/rendered4.toml"
    unset PERSONALIZATION_EMAIL
    generate_answer_file "${PROJECT_ROOT}/provision/host/answer-host.toml" \
        "sda" "KEY" "main" 'HASH' "$out"
    # The placeholder survives, which is what the build's guard detects.
    run cat "$out"
    assert_contains "$output" '__PERSONALIZATION_EMAIL__'
}

@test "generate_first_boot_script renders the bootstrap and marks it executable" {
    local out="${BATS_TMPDIR}/first-boot.sh"
    rm -f "$out"
    PERSONALIZATION_EMAIL="someone@example.com"
    run generate_first_boot_script "${PROJECT_ROOT}/provision/host/first-boot.sh" \
        "sda" "KEY" "main" 'HASH' "$out"
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
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--tmp /work'
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--tmp "$tmp_dir"'
}

@test "first-boot bootstrap is passed to prepare-iso in both carriers" {
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--on-first-boot "$first_boot"'
    assert_file_contains_literal "${PROJECT_ROOT}/provision/host/build-iso.sh" \
        '--on-first-boot "/work/$(basename "$FIRST_BOOT_WORK")"'
}

@test "frag/30 has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/30-create-guests.sh" 'BASH_SOURCE\[0\].*==.*\$0'
}

@test "frag/10 has source-guard" {
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" 'BASH_SOURCE\[0\].*==.*\$0'
}
