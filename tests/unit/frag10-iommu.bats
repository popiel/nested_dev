#!/usr/bin/env bats
# tests/unit/frag10-iommu.bats — test CPU vendor detection + IOMMU R4 from frag/10

load '../lib/helpers'

setup() {
    setup_mock_path
    source "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
}

teardown() {
    cleanup_mocks
}

# --- CPU vendor ---

@test "detect_cpu_vendor lowercases the lscpu vendor id" {
    create_mock "lscpu" 'echo "Vendor ID:                        GenuineIntel"'
    run detect_cpu_vendor
    [ "$output" = "genuineintel" ]
}

@test "detect_cpu_vendor returns empty when lscpu reports no vendor" {
    create_mock "lscpu" 'echo "Architecture:  x86_64"'
    run detect_cpu_vendor
    [ -z "$output" ]
}

# The kernel parameter differs per vendor, and a mismatch is silent: IOMMU
# simply stays off and the GPU group is never separable.
@test "iommu_flag_for_vendor maps each supported vendor" {
    create_mock "lscpu" 'echo "Vendor ID:  GenuineIntel"'
    run iommu_flag_for_vendor "$(detect_cpu_vendor)"
    [ "$output" = "intel_iommu=on" ]

    create_mock "lscpu" 'echo "Vendor ID:  AuthenticAMD"'
    run iommu_flag_for_vendor "$(detect_cpu_vendor)"
    [ "$output" = "amd_iommu=on" ]
}

@test "iommu_flag_for_vendor fails for a vendor with no known flag" {
    # Returning a flag for an unknown CPU would boot the host with IOMMU
    # silently disabled; the caller has to be able to abort.
    run iommu_flag_for_vendor "someothervendor"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- Audio companion ---

@test "find_audio_companion returns BDF for audio device" {
    create_mock "lspci" 'echo "01:00.0 VGA compatible controller: NVIDIA ..."
echo "01:00.1 Audio device: NVIDIA ..."'
    run find_audio_companion "01:00.0"
    [ "$output" = "01:00.1" ]
}

@test "find_audio_companion returns empty when no audio" {
    create_mock "lspci" 'echo "01:00.0 VGA compatible controller: NVIDIA ..."'
    run find_audio_companion "01:00.0"
    [ -z "$output" ]
}

# --- collect_gpu_ids: what actually reaches VFIO ---

@test "collect_gpu_ids excludes the virtio GPU" {
    # A PVE host always has a virtio VGA controller. Handing it to VFIO takes
    # away the console the operator is installing from, and on a headless host
    # leaves nothing to debug with.
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/lspci-multi-gpu.txt"
    export LSPCI_TABLE="01:00.0=10de:2204 01:00.1=10de:1aef 00:02.0=8086:9bc5 04:00.0=1af4:1050"
    local ids=() names=()
    run bash -c 'source "'"${PROJECT_ROOT}"'/provision/host/frag/10-gpu-passthrough.sh"
        log() { :; }
        declare -a ids=() names=()
        collect_gpu_ids ids names
        printf "%s\n" "${ids[@]}"'
    assert_contains "$output" "10de:2204"
    assert_not_contains "$output" "1af4:1050"
}

@test "collect_gpu_ids returns an empty set on a host with only a virtio GPU" {
    install_mock "lspci" "mock-lspci.sh"
    export LSPCI_FIXTURE_PATH="${FIXTURES_DIR}/lspci-no-gpu.txt"
    export LSPCI_TABLE="04:00.0=1af4:1050"
    run bash -c 'source "'"${PROJECT_ROOT}"'/provision/host/frag/10-gpu-passthrough.sh"
        log() { :; }
        declare -a ids=() names=()
        collect_gpu_ids ids names
        printf "%d\n" "${#ids[@]}"'
    [ "$output" = "0" ]
}

# --- IOMMU R4: a group with more than one device is not separable ---
#
# These previously created a temp dir and counted its own files, without ever
# calling the function they were named after, so the rule they claimed to cover
# had no coverage at all. iommu_group_device_count takes the directory as an
# argument precisely so the rule can be exercised here.

iommu_group() {
    # $1 = temp dir, rest = device BDFs placed in one group
    #
    # This reproduces the two properties of a real sysfs group the rule depends
    # on, and nothing else:
    #
    #   1. members are symlinks to device directories, not regular files. A mock
    #      of plain files is the one shape `find -type f` matches, so it passes
    #      a counting expression that returns 0 for every genuine group.
    #   2. members are named in full, as 0000:01:00.0, because that is what the
    #      kernel writes — lspci reports 01:00.0, and reconciling the two is the
    #      rule's problem to solve.
    #
    # The domain is a parameter rather than a constant. A group on a host whose
    # PCI domain is not 0000 still has to be judged by the same rule, so the
    # tests must not pass only because the fixture happens to sit in domain
    # zero. BDFs here are otherwise opaque labels; nothing in the rule should
    # depend on a particular bus number, device number or function.
    #
    # Usage: iommu_group <dir> <domain> <bdf>...
    #
    # The domain is required rather than optional with a default. <dir> <bdf>
    # and <dir> <domain> <bdf> are otherwise indistinguishable, and a guess
    # between them silently renames every member in the fixture.
    local dir="$1" domain="$2"; shift 2
    local bdf
    mkdir -p "${dir}/devices"
    for bdf in "$@"; do
        mkdir -p "${dir}/${bdf}"
        ln -sfn "../${bdf}" "${dir}/devices/${domain}:${bdf}"
    done
}

@test "a group built the way sysfs builds one is still counted" {
    # Pins the shape assumption directly, so a future change to the counting
    # expression cannot quietly stop matching real /sys.
    local tmpdir="${BATS_TMPDIR}/symlink-shape"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1
    # The members must be symlinks, not files, or this test is testing nothing.
    [ -L "${tmpdir}/devices/0000:01:00.0" ]
    [ ! -f "${tmpdir}/devices/0000:01:00.0" ]
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "2" ]
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0
    [ "$status" -ne 0 ]
}

@test "pci_bdf_short drops a domain but leaves a short address alone" {
    # lspci reports 01:00.0 and sysfs writes 0000:01:00.0. The rule has to
    # compare them, and it has to do so without assuming the domain is zero.
    run pci_bdf_short "0000:01:00.0"
    [ "$output" = "01:00.0" ]
    run pci_bdf_short "01:00.0"
    [ "$output" = "01:00.0" ]
    run pci_bdf_short "0001:af:00.0"
    [ "$output" = "af:00.0" ]
    # a full sysfs path still reduces to the address
    run pci_bdf_short "/sys/devices/pci0000:00/0000:1f:00.0"
    [ "$output" = "1f:00.0" ]
}

@test "a group in a non-zero PCI domain is judged by the same rule" {
    # The build host is not the deploy host, and neither is any of the fixtures
    # standing in for one. If the rule embedded a domain, it would pass every
    # test here — all of which used 0000: — and reject a real group whose
    # machine numbers its PCI bus differently.
    local tmpdir="${BATS_TMPDIR}/iommu-domain"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0001 01:00.0 01:00.1

    # the GPU and its audio companion are still recognised as a permitted pair
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0 01:00.1
    [ "$status" -eq 0 ]

    # and an unlisted member is still rejected
    iommu_group "$tmpdir" 0001 01:00.0 01:00.1 02:00.0
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0 01:00.1
    [ "$status" -ne 0 ]
}

@test "the rule does not depend on the bus, device or function numbers used" {
    # Same two shapes, deliberately on unrelated addresses, to show the outcome
    # comes from the group membership and not from a memorised layout.
    local a="${BATS_TMPDIR}/layout-a" b="${BATS_TMPDIR}/layout-b"
    rm -rf "$a" "$b"

    iommu_group "$a" 0000 00:1f.0
    run iommu_group_is_separable "${a}/devices" 00:1f.0
    [ "$status" -eq 0 ]

    iommu_group "$b" 0000 07:04.3 07:04.7
    run iommu_group_is_separable "${b}/devices" 07:04.3 07:04.7
    [ "$status" -eq 0 ]

    iommu_group "$b" 0000 0b:00.0 0b:00.1
    run iommu_group_is_separable "${b}/devices" 0b:00.0
    [ "$status" -ne 0 ]
}

@test "iommu_group_members lists the BDFs in a group" {
    local tmpdir="${BATS_TMPDIR}/members"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1
    run iommu_group_members "${tmpdir}/devices"
    [[ "$output" == *01:00.0* ]]
    [[ "$output" == *01:00.1* ]]
}

@test "iommu_group_device_count counts the devices in a group" {
    local tmpdir="${BATS_TMPDIR}/iommu"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "1" ]

    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "2" ]
}

@test "iommu_group_device_count reports zero for a group that does not exist" {
    # A GPU with no IOMMU group directory at all is not a separable-group
    # failure; main() skips those before consulting the rule.
    run iommu_group_device_count "${BATS_TMPDIR}/no-such-group/devices"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "R4: a single-device group is separable" {
    local tmpdir="${BATS_TMPDIR}/iommu-single"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0
    [ "$status" -eq 0 ]
}

@test "R4: a group with a second unrelated device is not separable" {
    # A third device alongside the GPU would follow it into the guest and take a
    # piece of the host's hardware with it.
    local tmpdir="${BATS_TMPDIR}/iommu-shared"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0
    [ "$status" -ne 0 ]
}

@test "R4: the GPU and its companion audio function are separable together" {
    # R-01.7.1 permits exactly this pairing, and R-01.6.5 requires it be passed
    # through together, so it is the one two-device group that must NOT abort.
    #
    # This is the case a count-based test gets wrong in both directions: a rule
    # of "at most one device" rejects the configuration the spec calls correct,
    # and it does so having verified nothing on hardware, because the count was
    # always 0 there.
    local tmpdir="${BATS_TMPDIR}/iommu-gpu-audio"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0 01:00.1
    [ "$status" -eq 0 ]
}

@test "R4: a third device alongside the audio function is not separable" {
    # Permitting the audio function must not permit anything else with it.
    local tmpdir="${BATS_TMPDIR}/iommu-triple"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1 01:00.2
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0 01:00.1
    [ "$status" -ne 0 ]
}

@test "R4: the audio function alone in its own group is separable" {
    local tmpdir="${BATS_TMPDIR}/iommu-audio-alone"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.1
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.1
    [ "$status" -eq 0 ]
}

@test "R4: a group with three devices is not separable either" {
    local tmpdir="${BATS_TMPDIR}/iommu-triple-plain"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 01:00.0 01:00.1 01:00.2
    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0
    [ "$status" -ne 0 ]
}

@test "check_iommu_group_separable maps a BDF to its sysfs group directory" {
    # The one part of check_iommu_group_separable that cannot be redirected to
    # a temp dir: the BDF-to-path mapping. Getting it wrong would check a
    # directory that never exists, which counts 0 devices and always passes.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    assert_contains "$src" '"/sys/bus/pci/devices/0000:${pci_addr}/iommu_group/devices"'
}

@test "main enforces the R4 rule through check_iommu_group_separable" {
    # Otherwise main() is free to re-derive group membership and drift from the
    # rule the tests cover, which is what it used to do. Asserted on the call
    # site, not on a particular argument list: the permitted companions are a
    # variable, and pinning the shape of the call would make a legitimate
    # change look like a regression.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    assert_file_matches "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" \
        'if ! check_iommu_group_separable "\$PCI_ADDR"'
    assert_file_matches "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" \
        'if \[ -d "\$AUDIO_GROUP_PATH" \]'
}

@test "the audio companion is identified before the group is judged" {
    # The permitted shape in R-01.7.1 names the companion audio function, so the
    # rule cannot be applied before that function is known. Judging first makes
    # the ordinary GPU-plus-its-own-audio pairing indistinguishable from the
    # unsafe group the rule exists to catch.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    local audio_line check_line
    audio_line=$(grep -n '^[[:space:]]*AUDIO_ADDR=\$(find_audio_companion' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" | head -1 | cut -d: -f1)
    check_line=$(grep -n 'if ! check_iommu_group_separable "\$PCI_ADDR"' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" | head -1 | cut -d: -f1)
    [ -n "$audio_line" ] || { echo "main() no longer finds the audio companion" >&2; return 1; }
    [ -n "$check_line" ] || { echo "main() no longer calls the rule" >&2; return 1; }
    [ "$audio_line" -lt "$check_line" ] || {
        echo "the group is judged at $check_line before the audio companion is known at $audio_line" >&2
        return 1
    }
}

@test "R4: the measured host layout — the iGPU alone is separable" {
    # Taken from a real host rather than invented. With VT-d enabled, this
    # machine reported:
    #   group 0:  0000:00:02.0
    # The Intel iGPU on its own. One member, nothing else follows it, so this is
    # the device that can be passed through.
    local tmpdir="${BATS_TMPDIR}/measured-igpu"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 00:02.0
    run iommu_group_is_separable "${tmpdir}/devices" 00:02.0
    [ "$status" -eq 0 ]
}

@test "R4: the measured host layout — the dGPU group is not separable" {
    # The same host reported both GTX 1080s, their audio functions, and the two
    # PCH root ports they sit behind all in group 2:
    #   0000:00:01.0  0000:00:01.1
    #   0000:01:00.0  0000:01:00.1
    #   0000:02:00.0  0000:02:00.1
    # Passing through "the 1080" here hands over the other 1080 and both root
    # ports. Permitting the audio function does not make it safe.
    local tmpdir="${BATS_TMPDIR}/measured-dgpu"
    rm -rf "$tmpdir"
    iommu_group "$tmpdir" 0000 \
        00:01.0 00:01.1 01:00.0 01:00.1 02:00.0 02:00.1

    run iommu_group_is_separable "${tmpdir}/devices" 01:00.0 01:00.1
    [ "$status" -ne 0 ]

    # and the root ports are what a device count alone would have hidden
    run iommu_group_members "${tmpdir}/devices"
    [[ "$output" == *"00:01.0"* ]]
    [[ "$output" == *"02:00.1"* ]]
    run iommu_group_device_count "${tmpdir}/devices"
    [ "$output" = "6" ]
}

@test "an unsafe candidate is dropped from the set, not fatal for the run" {
    # One unsafe device must not take the others with it. The previous version
    # exited on the first non-separable group, so the dGPU above aborted the
    # fragment — including the separable iGPU, and every fragment after it.
    # On this host that meant no passthrough and no guests at all.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")

    # A skip, not an exit, on the non-separable path.
    run grep -A 7 'if ! check_iommu_group_separable "\$PCI_ADDR"' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
    [[ "$output" == *"continue"* ]] || {
        echo "a non-separable group no longer skips the candidate:" >&2
        echo "$output" >&2
        return 1
    }
    [[ "$output" != *"exit 1"* ]] || {
        echo "the non-separable path still aborts the run:" >&2
        echo "$output" >&2
        return 1
    }

    # The set is rebuilt from the candidates that survived, not from everything
    # that was detected.
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" \
        'GPU_IDS=("${PASSTHROUGH_IDS[@]}")'

    # Having no usable candidate at all is still fatal, so a host where nothing
    # can be passed through is told so rather than quietly configuring vfio with
    # nothing in it.
    assert_file_contains "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh" \
        'if [ ${#GPU_IDS[@]} -eq 0 ]; then'
}

@test "a device with no IOMMU group is skipped, not fatal" {
    # IOMMU off for a device is a property of that device. It used to abort the
    # whole fragment, which meant a host with IOMMU disabled in firmware still
    # took out provisioning of everything that had nothing to do with it.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    run grep -A 4 'if \[ ! -d "\$GPU_GROUP_PATH" \]; then' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
    [[ "$output" == *"continue"* ]] || {
        echo "a device with no IOMMU group does not skip:" >&2
        echo "$output" >&2
        return 1
    }
    [[ "$output" != *"exit 1"* ]] || {
        echo "the missing-group branch still aborts the run:" >&2
        echo "$output" >&2
        return 1
    }
}

@test "the NVIDIA guest workaround follows the passthrough set, not detection" {
    # It walked every detected GPU, so on this host — where the 1080s are left
    # to the host because their group is unsafe — it would still promise a
    # workaround for a guest that never receives one of them.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    run grep -c 'for entry in "\${PASSTHROUGH_NAMES\[@\]}"; do' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
    [ "$output" -ge 1 ] || {
        echo "the NVIDIA workaround still iterates every detected GPU" >&2
        return 1
    }
}

@test "a changed passthrough set rewrites vfio-pci.ids in GRUB" {
    # The old guard was `grep -q intel_iommu=on`, and it short-circuited the
    # whole GRUB block. On a host where the flag was already set but the set had
    # since narrowed — this host, dropping the two unsafe dGPUs — GRUB kept the
    # stale id list and the kernel bound devices the provisioner had decided to
    # leave alone. Idempotent by flag-presence was worse than not idempotent.
    local frag="${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
    local src
    src=$(cat "$frag")

    assert_contains "$src" 'STALE_IDS=$(sed -n'
    assert_contains "$src" 'Replacing stale vfio-pci.ids'
    # the whole block must not be short-circuited by the flag being present
    run grep -c 'if grep -q "intel_iommu=on|amd_iommu=on" "\$GRUB_FILE"' "$frag"
    [ "$output" -eq 0 ] || {
        echo "the GRUB block is still short-circuited on the IOMMU flag" >&2
        return 1
    }
}

@test "the separability rule counts directory entries, not regular files" {
    # Guards the regression itself. `find -type f` is the natural expression
    # here and it is wrong: sysfs publishes group members as symlinks to device
    # directories, so it returns 0 for every real group and the rule never fires.
    local src
    src=$(cat "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh")
    run grep -c 'find "\$group_path" -maxdepth 1 -type f' \
        "${PROJECT_ROOT}/provision/host/frag/10-gpu-passthrough.sh"
    [ "$output" -eq 0 ] || {
        echo "iommu_group_device_count is back to matching regular files only" >&2
        return 1
    }
    assert_contains "$src" 'find "$group_path" -mindepth 1 -maxdepth 1 -print'
}
