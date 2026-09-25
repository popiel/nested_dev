#!/usr/bin/env bash
# build-iso.sh — Build PVE 9.2 autoinstall ISO
# Downloads PVE ISO, injects answer file, produces proxmox-ve_9.2-1_auto.iso
# Uses proxmox-auto-install-assistant prepare-iso (native or Docker).
# REF: __GITHUB_REF__ (resolved at build time)
#
# Requirements: Linux x86_64 (or Git Bash/WSL), wget,
#               proxmox-auto-install-assistant (native or Docker)
# Usage: ./build-iso.sh
set -euo pipefail

# --- Utilities (must be defined before first use) ---
log() { printf '[build-iso] %s\n' "$*"; }
die() { printf '[build-iso] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Git Bash (MSYS2) compatibility ---
# When Git Bash invokes a native Windows binary such as docker.exe, the MSYS
# runtime rewrites any argument that looks like a POSIX path:
#   "/work"             -> "C:/Program Files/Git/work"  (resolved against the
#                          Git install root, not the Windows drive)
#   ".../output/iso:/iso" -> shredded, because the "o:" in "iso:" is read as a
#                          Windows drive letter
# Either rewrite breaks the bind mounts and the container-side paths, so the
# assistant silently operates on nonexistent files. is_msys detects the shell,
# host_path pre-converts host paths to the form docker.exe expects, and
# docker_noconv disables the rewriting entirely.

is_msys() {
    [ -n "${MSYSTEM:-}" ] && command -v cygpath >/dev/null 2>&1
}

# Convert a host path for use as a docker bind-mount source.
# cygpath -m yields forward slashes, which Docker Desktop on Windows accepts.
host_path() {
    if is_msys; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Run docker with MSYS argument conversion disabled. Both variables are set:
# MSYS_NO_PATHCONV is the documented switch, MSYS2_ARG_CONV_EXCL is honoured
# more consistently across Git Bash versions.
docker_noconv() {
    if is_msys; then
        MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
    else
        docker "$@"
    fi
}

# --- Pure functions (testable via source-guard) ---

download_iso() {
    local url="$1" dest="$2"
    if command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "$dest" "$url"
    else
        die "Missing: wget"
    fi
}

sed_escape() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//|/\\|}"
    val="${val//&/\\&}"
    val="${val//\$/\\\$}"
    echo "$val"
}

# Hash a file, failing loudly when it is missing or empty.
# A bare `sha256sum` inside a command substitution returns a non-zero status
# that `set -e` cannot see (the enclosing log/cat succeeds), which is how a
# missing ISO previously produced a blank hash in the manifest.
sha256_of() {
    local file="$1"
    [ -f "$file" ] || die "Expected file not found: ${file}"
    [ -s "$file" ] || die "Expected file is empty: ${file}"
    sha256sum "$file" | awk '{print $1}'
}

# Append one build record to the manifest. All values are passed in already
# computed and verified; the heredoc performs no command substitution, so a
# manifest entry can never be written from a failed build.
write_manifest() {
    local manifest="$1" ref="$2" ref_sha="$3" pve_name="$4" pve_sha="$5" \
          auto_name="$6" auto_sha="$7" disk="$8" ssh_key_file="$9"

    cat >> "$manifest" <<EOF

## Host ISO build — $(date -Is)
REF: ${ref}
REF SHA: ${ref_sha}
PVE ISO: ${pve_name}
PVE ISO SHA256: ${pve_sha}
Auto ISO: ${auto_name}
Auto ISO SHA256: ${auto_sha}
Target disk: ${disk}
SSH key: ${ssh_key_file}
Password hash: embedded in answer (root-password-hashed) and first-boot bootstrap
EOF
}

detect_target_disk() {
    local target=""
    for disk in /dev/nvme?n?; do
        [ -b "$disk" ] && target="$disk" && break
    done
    if [ -z "$target" ]; then
        for disk in /dev/sd?; do
            if [ -f "/sys/block/$(basename "$disk")/queue/rotational" ]; then
                local rota
                rota=$(cat "/sys/block/$(basename "$disk")/queue/rotational")
                if [ "$rota" -eq 0 ]; then
                    target="$disk"
                    break
                fi
            fi
        done
    fi
    if [ -z "$target" ]; then
        for disk in /dev/sd?; do
            [ -b "$disk" ] && target="$disk" && break
        done
    fi
    echo "$target"
}

# proxmox-auto-install-assistant exits 0 even when it reports a hard failure
# (e.g. a TOML parse error), so its exit status cannot gate the build on its
# own. Match the tool's own failure markers instead, and fail fast — otherwise
# a typo in the answer file is only discovered after rebuilding a 1.7 GB ISO.
assistant_reports_error() {
    printf '%s\n' "$1" | grep -qiE '^(error|fatal|.*Found issues in the answer file)'
}

# Run the assistant with its output captured, echo that output, and treat
# either a non-zero status or a reported error as failure.
run_assistant_checked() {
    local failure_message="$1"
    shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$rc" -ne 0 ] && die "${failure_message} (exit ${rc})"
    assistant_reports_error "$out" && die "$failure_message"
    return 0
}

# Render a build-time template, replacing the shared __PLACEHOLDER__ set.
# Used for both the answer file and the first-boot bootstrap, so the two
# cannot drift apart on escaping or placeholder names.
# Argument order matches the historical generate_answer_file contract, with
# the destination last.
render_template() {
    local template="$1" disk_short="$2" ssh_key="$3" ref="$4" password_hash="$5" output="$6"
    local escaped_hash
    # Fall back to the literal placeholder when personalization was not sourced,
    # so the caller's unsubstituted-placeholder check fails loudly rather than
    # silently rendering an invalid empty value.
    local email="${PERSONALIZATION_EMAIL:-__PERSONALIZATION_EMAIL__}"
    escaped_hash=$(sed_escape "$password_hash")
    sed \
        -e "s|__ROOT_SSH_KEY__|${ssh_key}|g" \
        -e "s|__AUTO_DETECT_DISK__|${disk_short}|g" \
        -e "s|__GITHUB_REF__|${ref}|g" \
        -e "s|__ROOT_PASSWORD_HASH__|${escaped_hash}|g" \
        -e "s|__PERSONALIZATION_EMAIL__|${email}|g" \
        "$template" > "$output"
}

generate_answer_file() {
    render_template "$@"
}

# The first-boot bootstrap is embedded in the ISO and carries the root password
# hash, so it is rendered into the (gitignored) work dir and must be readable
# and executable before prepare-iso reads it.
generate_first_boot_script() {
    local template="$1" disk_short="$2" ssh_key="$3" ref="$4" password_hash="$5" output="$6"
    render_template "$template" "$disk_short" "$ssh_key" "$ref" "$password_hash" "$output"
    chmod 700 "$output"
}

run_prepare_iso() {
    local assistant="$1" pve_iso="$2" answer="$3" auto_iso="$4" first_boot="$5" tmp_dir="$6"
    log "Building autoinstall ISO via ${assistant}..."
    # --tmp is mandatory: the assistant otherwise stages in the source ISO's
    # directory, which is mounted read-only in the container.
    $assistant prepare-iso "$pve_iso" \
        --fetch-from iso \
        --answer-file "$answer" \
        --on-first-boot "$first_boot" \
        --tmp "$tmp_dir" \
        --output "$auto_iso"
    log "Autoinstall ISO built: ${auto_iso}"
    log "SHA256: $(sha256_of "$auto_iso")"
}

# --- Main execution (guarded for source-testability) ---

main() {
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    OUTPUT_DIR="${REPO_ROOT}/output"
    ISO_DIR="${OUTPUT_DIR}/iso"
    WORK_DIR="${OUTPUT_DIR}/build-work"

    # Source shared personalization (§05)
    . "${REPO_ROOT}/provision/personalization.sh"
    REF="${PERSONALIZATION_REF}"
    REF_SHA=$(resolve_ref_to_sha "${PERSONALIZATION_REPO}" "$REF")
    if [ -z "$REF_SHA" ]; then
        log "WARNING: could not resolve ${PERSONALIZATION_REPO}@${REF} to a SHA"
        log "WARNING: manifest will record the ref as unresolved (offline or git unavailable)"
        REF_SHA="unresolved"
    fi

    # --- Preflight ---
    for cmd in wget sha256sum; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
    done

    # Password hash (not committed — read at build time only)
    PASSWORD_HASH_FILE="${REPO_ROOT}/keys/password-hash"
    [ -f "$PASSWORD_HASH_FILE" ] || die "Missing: ${PASSWORD_HASH_FILE} (generate with mkpasswd)"
    PASSWORD_HASH=$(tr -d '\n' < "$PASSWORD_HASH_FILE")

    mkdir -p "$ISO_DIR" "$WORK_DIR"

    # --- 1. Download PVE ISO ---
    PVE_ISO_URL="https://na.cdn.proxmox.com/iso/proxmox-ve_9.2-1.iso"
    PVE_ISO_NAME="proxmox-ve_9.2-1.iso"
    PVE_ISO_PATH="${ISO_DIR}/${PVE_ISO_NAME}"
    PVE_ISO_SHA256="4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"

    if [ ! -s "$PVE_ISO_PATH" ]; then
        rm -f "$PVE_ISO_PATH"
        log "Downloading PVE 9.2 ISO..."
        if ! download_iso "$PVE_ISO_URL" "$PVE_ISO_PATH"; then
            rm -f "$PVE_ISO_PATH"
            die "Download failed — check network connectivity and URL: ${PVE_ISO_URL}"
        fi
        log "Downloaded: $(sha256_of "$PVE_ISO_PATH")"
    else
        log "PVE ISO already present: $PVE_ISO_PATH"
    fi

    # Always verify SHA256; re-download once on mismatch
    if ! echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - >/dev/null 2>&1; then
        log "SHA256 mismatch — re-downloading PVE ISO..."
        rm -f "$PVE_ISO_PATH"
        if ! download_iso "$PVE_ISO_URL" "$PVE_ISO_PATH"; then
            rm -f "$PVE_ISO_PATH"
            die "Re-download failed — check network connectivity"
        fi
        echo "${PVE_ISO_SHA256}  ${PVE_ISO_PATH}" | sha256sum -c - \
            || die "ISO SHA256 mismatch after re-download"
        log "PVE ISO SHA256 verified (re-downloaded)"
    else
        log "PVE ISO SHA256 verified"
    fi

    # --- 2. Read SSH public key ---
    SSH_KEY_FILE="${REPO_ROOT}/keys/host_os_ed25519.pub"
    if [ ! -f "$SSH_KEY_FILE" ]; then
        die "SSH public key not found: ${SSH_KEY_FILE}"
    fi
    SSH_KEY=$(tr -d '\n' < "$SSH_KEY_FILE")
    log "SSH key loaded from ${SSH_KEY_FILE}"

    # --- 3. Auto-detect target disk ---
    TARGET_DISK=$(detect_target_disk)
    if [ -n "$TARGET_DISK" ]; then
        DISK_SHORT=$(basename "$TARGET_DISK")
        log "Target disk: ${TARGET_DISK} (${DISK_SHORT})"
    else
        DISK_SHORT="sda"
        log "WARNING: No disk detected, defaulting to ${DISK_SHORT}"
    fi

    # --- 4. Render build-time templates ---
    ANSWER_TEMPLATE="${SCRIPT_DIR}/answer-host.toml"
    ANSWER_WORK="${WORK_DIR}/answer-host.toml"
    FIRST_BOOT_TEMPLATE="${SCRIPT_DIR}/first-boot.sh"
    FIRST_BOOT_WORK="${WORK_DIR}/first-boot.sh"

    [ -f "$ANSWER_TEMPLATE" ] || die "Answer template not found: ${ANSWER_TEMPLATE}"
    [ -f "$FIRST_BOOT_TEMPLATE" ] || die "First-boot template not found: ${FIRST_BOOT_TEMPLATE}"

    generate_answer_file "$ANSWER_TEMPLATE" "$DISK_SHORT" "$SSH_KEY" "$REF" \
        "$PASSWORD_HASH" "$ANSWER_WORK"
    log "Answer file generated: ${ANSWER_WORK}"

    # The first-boot bootstrap carries the password hash, so it is rendered with
    # the same escaping and kept in the gitignored work dir. It replaces the
    # [late-commands] section the answer file used to carry.
    generate_first_boot_script "$FIRST_BOOT_TEMPLATE" "$DISK_SHORT" "$SSH_KEY" "$REF" \
        "$PASSWORD_HASH" "$FIRST_BOOT_WORK"
    log "First-boot bootstrap generated: ${FIRST_BOOT_WORK}"
    for rendered in "$FIRST_BOOT_WORK" "$ANSWER_WORK"; do
        if grep -q '__[A-Z_][A-Z_]*__' "$rendered"; then
            die "Unsubstituted placeholder remains in ${rendered}"
        fi
    done

    # --- 5. Validate answer file ---
    ASSISTANT=""
    if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
        ASSISTANT="proxmox-auto-install-assistant"
    elif command -v docker >/dev/null 2>&1; then
        ASSISTANT="docker"
    else
        die "No proxmox-auto-install-assistant found.
  Install natively: apt install proxmox-auto-install-assistant xorriso
  Or install Docker and run: ./build-iso.sh (will pull container image)"
    fi

    if [ "$ASSISTANT" = "docker" ]; then
        log "Using Docker to run proxmox-auto-install-assistant..."
        # Build image from in-repo Dockerfile on first use
        ASSISTANT_IMAGE="nested-dev-proxmox-assistant"
        ASSISTANT_DF="${SCRIPT_DIR}/Dockerfile.autoinstall-assistant"
        if ! docker_noconv image inspect "$ASSISTANT_IMAGE" >/dev/null 2>&1; then
            [ -f "$ASSISTANT_DF" ] || die "Dockerfile not found: ${ASSISTANT_DF}"
            log "Building ${ASSISTANT_IMAGE} from Dockerfile..."
            docker_noconv build -t "$ASSISTANT_IMAGE" \
                -f "$(host_path "$ASSISTANT_DF")" "$(host_path "$SCRIPT_DIR")" \
                || die "Failed to build ${ASSISTANT_IMAGE}"
        fi
    fi

    # Validate answer file
    if [ "$ASSISTANT" = "docker" ]; then
        log "Validating answer file schema..."
        run_assistant_checked \
            "Answer file schema check failed — fix answer-host.toml" \
            docker_noconv run --rm \
                -v "$(host_path "$WORK_DIR"):/work" \
                "$ASSISTANT_IMAGE" \
                validate-answer "/work/$(basename "$ANSWER_WORK")"
    else
        log "Validating answer file schema..."
        run_assistant_checked \
            "Answer file schema check failed — fix answer-host.toml" \
            "$ASSISTANT" validate-answer "$ANSWER_WORK"
    fi

    # --- 6. Build autoinstall ISO ---
    AUTO_ISO="${OUTPUT_DIR}/proxmox-ve_9.2-1_auto.iso"
    rm -f "$AUTO_ISO"

    if [ "$ASSISTANT" = "docker" ]; then
        docker_noconv run --rm \
            -v "$(host_path "$ISO_DIR"):/iso:ro" \
            -v "$(host_path "$WORK_DIR"):/work" \
            -v "$(host_path "$OUTPUT_DIR"):/output" \
            "$ASSISTANT_IMAGE" \
            prepare-iso "/iso/${PVE_ISO_NAME}" \
                --fetch-from iso \
                --answer-file "/work/$(basename "$ANSWER_WORK")" \
                --on-first-boot "/work/$(basename "$FIRST_BOOT_WORK")" \
                --tmp /work \
                --output "/output/$(basename "$AUTO_ISO")" \
            || die "prepare-iso failed"
    else
        run_prepare_iso "$ASSISTANT" "$PVE_ISO_PATH" "$ANSWER_WORK" "$AUTO_ISO" \
            "$FIRST_BOOT_WORK" "$WORK_DIR"
    fi

    # --- 7. Verify the artifact before reporting success ---
    # proxmox-auto-install-assistant can exit 0 after printing its own errors,
    # so the presence and non-emptiness of the ISO is the only trustworthy
    # success signal. Compute every hash here, before the manifest is written.
    AUTO_ISO_SHA256=$(sha256_of "$AUTO_ISO")
    PVE_ISO_SHA256_VERIFIED=$(sha256_of "$PVE_ISO_PATH")

    log "Autoinstall ISO built: ${AUTO_ISO}"
    log "SHA256: ${AUTO_ISO_SHA256}"

    # --- 8. Record manifest ---
    MANIFEST="${OUTPUT_DIR}/MANIFEST"
    write_manifest "$MANIFEST" "$REF" "$REF_SHA" \
        "$PVE_ISO_NAME" "$PVE_ISO_SHA256_VERIFIED" \
        "$(basename "$AUTO_ISO")" "$AUTO_ISO_SHA256" \
        "$DISK_SHORT" "$SSH_KEY_FILE"

    log "Manifest updated: ${MANIFEST}"
    log "=== Build complete ==="
    log "Write ${AUTO_ISO} to USB or serve over HTTP for unattended install."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
