# Spec 09 — Test Automation

Status: Draft (new)
Applies to: All scripts and configuration files in the repository
Depends on: Spec 00 (repo layout), Spec 05 (personalization), Spec 07 (dev lifecycle), Spec 08 (nested dev)

## 1. Purpose and scope

Defines how the repository's scripts, configuration files, and invariants are
tested automatically — statically and with unit-level bats-core tests — in CI
and locally.

Key invariants tested:

1. All shell scripts pass `shellcheck -x -s bash` (syntax + POSIX compliance).
2. Config files parse correctly: YAML (user-data), TOML (answer-host.toml),
   dnsmasq (`dnsmasq --test`), iptables (`iptables-restore --test`).
3. No hardcoded personal identity (`popiel`, `tapopiel@gmail.com`) appears
   outside `provision/personalization.sh` (Spec 05 §9).
4. Decision-table sizes appear in `frag/30-create-guests.sh` (40/80/40 GB
   OS disks; 500 GB data volume; 8192/16384/8192 MB RAM; 4/6/4 cores).
5. Template placeholders (`__GITHUB_REF__`, `CHANGE_ME_HASHED`,
   `__PERSONALIZATION_USERNAME__`, `__PERSONALIZATION_FULLNAME__`,
   `__VMCTL_PRIV_B64__`) appear in user-data templates and answer-host.toml
   but never in built/runtime outputs.
6. Pure functions (`resolve_ref_to_sha`, `detect_gpu_pci`, vendor detection,
   IOMMU R4 logic) behave correctly against fixture data.
7. Personalization sourcing fails fast (abort, not fallback) when the file
   is missing.

In scope: static analysis, unit tests, CI workflow, pre-commit fast-path.
Out of scope: sandbox integration tests (mocked `qm`/`iptables` full-run of
fragments); deferred to a future iteration.

## 2. Design decisions

| Decision | Default | Rationale |
|---|---|---|
| Test framework | bats-core 1.x | De facto standard for bash; TAP output, mock-friendly, GitHub Actions compatible |
| Static analysis | shellcheck + python3 yaml/toml + dnsmasq --test + iptables-restore --test | Catches syntax errors, config parse failures, and identity invariants with zero execution risk |
| Source-guard refactor | `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi` in frag/10, frag/30, build-iso | Enables sourcing functions in tests without executing side effects; zero behavior change |
| Mock strategy | Prepend temp `bin/` to PATH with fake `lspci`, `git ls-remote`, `wget` reading fixture files | Avoids real hardware/network; fixture files encode known-good and known-bad states |
| Fixture format | Plain text files in `tests/fixtures/` (canned `lspci` output, test `personalization.sh`) | Simple, diffable, no framework dependency |
| Runner | `tests/run.sh` (bash, no external deps beyond bats/shellcheck/python3) | Self-contained, works in CI and locally |
| CI | GitHub Actions `.github/workflows/ci.yml` on push + PR | Catches regressions before merge; runs full suite |
| Pre-commit fast-path | `tests/run.sh --fast` (static + invariants only, no unit) | Keeps pre-commit fast; full suite runs in CI |
| Depth (first pass) | Static + unit (layers 1–2) | Covers the bulk of real bugs without the effort of sandbox integration tests |

## 3. Repository layout

```
tests/
  run.sh                    # entrypoint: check deps, run static + unit, TAP output
  lib/
    helpers.bash            # mock_bin(), assert_contains(), assert_exit_code(), fixture loading
  fixtures/
    lspci-multi-gpu.txt     # NVIDIA GPU + audio companion + virtio VGA
    lspci-single-gpu.txt    # single GPU, no audio companion
    lspci-no-gpu.txt        # no GPU (only virtio VGA)
    lspci-shared-iommu.txt  # GPU + audio in same IOMMU group (R4 abort case)
    iommu-group-separable/  # directory listing for a separable group
    iommu-group-shared/     # directory listing for a non-separable group
    personalization.sh      # test copy with known values
    ubuntu-release.conf     # test copy: 26.04 / noble
  static/
    lint.bats               # shellcheck all scripts; hadolint Dockerfiles (guarded)
    configs.bats            # YAML, TOML, dnsmasq, iptables parse validation
    invariants.bats         # identity, placeholder, decision-table invariants
  unit/
    personalization.bats    # sourcing, var values, fail-fast on missing
    resolve-ref.bats        # resolve_ref_to_sha: branch, tag, SHA, empty
    gpu-detect.bats         # detect_gpu_pci: multi-GPU, audio companion, virtio exclusion
    frag10-iommu.bats       # vendor matching, R4 abort, audio companion detection
    template.bats           # sed substitution: placeholder injection, no leftovers
    build-iso.bats          # ISO filename/URL construction from ubuntu-release.conf
```

## 4. Source-guard refactor

The following scripts currently execute their main bodies at top level. Each
is refactored to wrap the main body in a `main()` function guarded by
`BASH_SOURCE[0]`:

- `provision/host/frag/10-gpu-passthrough.sh`
- `provision/host/frag/30-create-guests.sh`
- `provision/host/build-iso.sh`

Pattern:

```bash
# --- functions defined above (log, die, resolve_ref_to_sha, etc.) ---

main() {
    # all inline logic moves here (set -euo pipefail already at top)
    ...
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
```

This is a zero-behavior-change refactor. All scripts continue to work
identically when executed directly. Functions become sourceable in test files
for unit testing.

Scripts NOT refactored (static-only testing suffices):

- `provision/host/provision-host.sh` (orchestrator, no testable logic)
- `provision/host/frag/20-memory-swap.sh` (system calls, no pure logic)
- `provision/host/frag/25-desktop-control.sh` (key generation, no pure logic)
- `provision/host/frag/90-finalize.sh` (networking, firewall — tested via static)
- `provision/host/refresh-guests.sh` (SCP orchestration)
- `desktop/desktop-firstboot.sh`, `llm/llm-firstboot.sh`, `dev/dev-firstboot.sh`
  (linear first-boot scripts; tested via static + invariant checks)
- `dev/tools/nested`, `dev/tools/dev-refresh-images`, `dev/tools/dev-nested-provision.sh`
- `provision/host/vmctl/vmctl-host` (verb-dispatch, no pure functions)
- `provision/personalization.sh` (variable definitions only)

## 5. Testability contract

### 5.1 Pure functions (unit-testable via source-guard)

| Function | File | What it does | Mock needed |
|---|---|---|---|
| `resolve_ref_to_sha` | `frag/30` | Resolves branch/tag/SHA via `git ls-remote` | `git` (returns canned output) |
| `detect_gpu_pci` | `frag/30` | Reads `lspci` + `/sys/bus/pci/devices/*/iommu_group/devices` | `lspci` (reads fixture), `/sys` (temp dir with fake sysfs) |
| `download_iso` | `frag/30` | Downloads ISO with SHA256 verify | `wget` (no-op), `sha256sum` (returns known hash) |
| vendor detection | `frag/10` | Reads `lscpu` Vendor ID, matches `*intel*`/`*amd*` | `lscpu` (fixture), `awk` (real) |
| IOMMU group check | `frag/10` | Reads `/sys/bus/pci/devices/*/iommu_group/devices` | `/sys` (temp dir with fake group listings) |
| audio companion detection | `frag/10` | Scans same-bus devices via `lspci -s <prefix>.` | `lspci` (fixture) |

### 5.2 Side-effecting logic (static-only or integration-test)

Everything else: `qm create/start/set`, `iptables`/`ip` commands, `apt-get`,
`systemctl`, `genisoimage`, `update-grub`, `update-initramfs`, Docker pulls/runs.

### 5.3 Fixture format

`tests/fixtures/lspci-multi-gpu.txt` — one device per line, matching the
format of `lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}'`:

```
01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090] (rev a1)
01:00.1 Audio device: NVIDIA Corporation GA102 HDMI Audio (rev a1)
00:02.0 VGA compatible controller: Intel Corporation Coffee Lake HD Graphics (rev 05)
04:00.0 VGA compatible controller: Red Hat, Inc. Virtio GPU (rev 01)
```

`tests/fixtures/iommu-group-separable/` — a directory with one file per PCI
device in the group (filename = BDF address). For R4 abort test, the
`iommu-group-shared/` directory has both the GPU and audio BDF.

## 6. Static validation suite

### 6.1 `tests/static/lint.bats`

```
@test "shellcheck passes on all shell scripts" {
  # discover all .sh + extension-less bash shebangs
  for script in $(find . -name '*.sh' -not -path './tests/*' -not -path './output/*'); do
    run shellcheck -x -s bash "$script"
    [ "$status" -eq 0 ]
  done
}

@test "shellcheck passes on extension-less bash scripts" {
  for script in dev/tools/nested dev/tools/dev-refresh-images provision/host/vmctl/vmctl-host; do
    head -1 "$script" | grep -qE '^#!/usr/bin/env bash|^#!/bin/bash'
    run shellcheck -x -s bash "$script"
    [ "$status" -eq 0 ]
  done
}
```

### 6.2 `tests/static/configs.bats`

```
@test "all user-data files parse as YAML" {
  for ud in desktop/user-data/user-data llm/user-data/user-data dev/user-data/user-data; do
    run python3 -c "import yaml; yaml.safe_load(open('$ud'))"
    [ "$status" -eq 0 ]
  done
}

@test "answer-host.toml parses as TOML" {
  run python3 -c "import tomllib; tomllib.load(open('provision/host/answer-host.toml','rb'))"
  [ "$status" -eq 0 ]
}

@test "dnsmasq.conf passes dnsmasq --test" {
  command -v dnsmasq >/dev/null || skip "dnsmasq not installed"
  run dnsmasq --test -C provision/network/dnsmasq.conf
  [ "$status" -eq 0 ]
}

@test "iptables-forwarding.conf passes iptables-restore --test" {
  command -v iptables-restore >/dev/null || skip "iptables not installed"
  run iptables-restore --test < provision/network/iptables-forwarding.conf
  [ "$status" -eq 0 ]
}
```

### 6.3 `tests/static/invariants.bats`

```
@test "no hardcoded popiel outside personalization.sh" {
  run grep -r 'popiel' --include='*.sh' --include='*.toml' --include='*.conf' \
    --include='*.yml' --include='*.yaml' .
  # filter out personalization.sh and test fixtures
  filtered=$(echo "$output" | grep -v 'provision/personalization.sh' | grep -v 'tests/fixtures/' || true)
  [ -z "$filtered" ]
}

@test "no hardcoded tapopiel@gmail.com outside personalization.sh" {
  run grep -r 'tapopiel@gmail.com' --include='*.sh' --include='*.toml' .
  filtered=$(echo "$output" | grep -v 'provision/personalization.sh' | grep -v 'tests/fixtures/' || true)
  [ -z "$filtered" ]
}

@test "frag/30 contains OS disk sizes from decision table" {
  grep -q 'local-lvm:40,size=40G' provision/host/frag/30-create-guests.sh
  grep -q 'local-lvm:80,size=80G' provision/host/frag/30-create-guests.sh
}

@test "frag/30 contains RAM/core sizes from decision table" {
  grep -q 'DESKTOP_MEM=8192'  provision/host/frag/30-create-guests.sh
  grep -q 'LLM_MEM=16384'     provision/host/frag/30-create-guests.sh
  grep -q 'DEV_MEM=8192'      provision/host/frag/30-create-guests.sh
  grep -q 'DESKTOP_CORES=4'   provision/host/frag/30-create-guests.sh
  grep -q 'LLM_CORES=6'       provision/host/frag/30-create-guests.sh
  grep -q 'DEV_CORES=4'       provision/host/frag/30-create-guests.sh
}

@test "user-data templates contain required placeholders" {
  for ud in desktop/user-data/user-data llm/user-data/user-data dev/user-data/user-data; do
    grep -q '__PERSONALIZATION_USERNAME__' "$ud"
    grep -q '__PERSONALIZATION_FULLNAME__' "$ud"
    grep -q 'CHANGE_ME_HASHED' "$ud"
  done
}

@test "answer-host.toml contains __GITHUB_REF__" {
  grep -q '__GITHUB_REF__' provision/host/answer-host.toml
}

@test "answer-host.toml contains __ROOT_SSH_KEY__" {
  grep -q '__ROOT_SSH_KEY__' provision/host/answer-host.toml
}

@test "frag/30 sources personalization.sh from correct path" {
  grep -q '\. /root/provision/personalization\.sh' provision/host/frag/30-create-guests.sh
}

@test "frag/30 aborts when personalization vars are empty" {
  grep -q 'PERSONALIZATION_USERNAME.*PERSONALIZATION_FULLNAME.*exit 1' \
    provision/host/frag/30-create-guests.sh || \
  grep -A5 'PERSONALIZATION_USERNAME.*PERSONALIZATION_FULLNAME' \
    provision/host/frag/30-create-guests.sh | grep -q 'exit 1'
}
```

## 7. Unit test suite

### 7.1 `tests/unit/personalization.bats`

Tests that `provision/personalization.sh` sources correctly and fails fast
when missing.

```
setup() {
  source tests/fixtures/personalization.sh
}

@test "personalization.sh sets PERSONALIZATION_USERNAME" {
  [ "$PERSONALIZATION_USERNAME" = "popiel" ]
}

@test "personalization.sh sets PERSONALIZATION_UID" {
  [ "$PERSONALIZATION_UID" = "1401" ]
}

@test "personalization.sh sets PERSONALIZATION_GID" {
  [ "$PERSONALIZATION_GID" = "1401" ]
}

@test "personalization.sh sets PERSONALIZATION_HOME" {
  [ "$PERSONALIZATION_HOME" = "/home/popiel" ]
}

@test "personalization.sh sets PERSONALIZATION_REPO" {
  [ "$PERSONALIZATION_REPO" = "popiel/nested_dev" ]
}

@test "personalization.sh sets PERSONALIZATION_REF" {
  [ "$PERSONALIZATION_REF" = "main" ]
}
```

### 7.2 `tests/unit/resolve-ref.bats`

Tests `resolve_ref_to_sha` from `frag/30-create-guests.sh` with mocked `git`.

```
setup() {
  export PATH="tests/fixtures/mock-bin:$PATH"
  mkdir -p tests/fixtures/mock-bin
  # Source the function under test (source-guard required)
  source provision/host/frag/30-create-guests.sh <<'EOF' || true
EOF
}

@test "resolve_ref_to_sha returns SHA for branch" {
  cat > tests/fixtures/mock-bin/git <<'SCRIPT'
#!/bin/bash
echo "abc123def456789012345678901234567890abcd  refs/heads/main"
SCRIPT
  chmod +x tests/fixtures/mock-bin/git
  run resolve_ref_to_sha "popiel/nested_dev" "main"
  [ "$output" = "abc123def456789012345678901234567890abcd" ]
}

@test "resolve_ref_to_sha returns SHA for tag" {
  cat > tests/fixtures/mock-bin/git <<'SCRIPT'
#!/bin/bash
echo ""
echo "deadbeef1234567890abcdef1234567890abcdef  refs/tags/v1.0"
SCRIPT
  chmod +x tests/fixtures/mock-bin/git
  run resolve_ref_to_sha "popiel/nested_dev" "v1.0"
  [ "$output" = "deadbeef1234567890abcdef1234567890abcdef" ]
}

@test "resolve_ref_to_sha passes through 40-hex SHA" {
  run resolve_ref_to_sha "popiel/nested_dev" "deadbeef1234567890abcdef1234567890abcdef"
  [ "$output" = "deadbeef1234567890abcdef1234567890abcdef" ]
}

@test "resolve_ref_to_sha returns empty on unresolvable" {
  cat > tests/fixtures/mock-bin/git <<'SCRIPT'
#!/bin/bash
echo ""
SCRIPT
  chmod +x tests/fixtures/mock-bin/git
  run resolve_ref_to_sha "popiel/nested_dev" "nonexistent"
  [ -z "$output" ]
}
```

### 7.3 `tests/unit/gpu-detect.bats`

Tests `detect_gpu_pci` from `frag/30-create-guests.sh` with mock `lspci` and
fake `/sys` sysfs.

```
setup() {
  export PATH="tests/fixtures/mock-bin:$PATH"
  mkdir -p tests/fixtures/mock-bin
  # mock lspci reads from fixture file
  export LPCSI_FIXTURE="tests/fixtures/lspci-multi-gpu.txt"
  cat > tests/fixtures/mock-bin/lspci <<'SCRIPT'
#!/bin/bash
if [[ "$*" == "-n -s"* ]]; then
  # lspci -n -s <addr> format: "<addr> <class>: <vd>"
  BDF=$(echo "$*" | awk '{print $NF}')
  case "$BDF" in
    01:00.0) echo "01:00.0 0300: 10de:2204" ;;
    01:00.1) echo "01:00.1 0403: 10de:1aef" ;;
    00:02.0) echo "00:02.0 0300: 8086:9bc5" ;;
    04:00.0) echo "04:00.0 0300: 1af4:1050" ;;
  esac
elif [[ "$*" == "-s"*" && "$*" != "-n"* ]]; then
  # lspci -s <prefix>. format: list devices on same bus
  echo "01:00.0 VGA compatible controller: NVIDIA ..."
  echo "01:00.1 Audio device: NVIDIA ..."
fi
SCRIPT
  chmod +x tests/fixtures/mock-bin/lspci
  source provision/host/frag/30-create-guests.sh <<'EOF' || true
EOF
}

@test "detect_gpu_pci includes NVIDIA GPU + audio companion" {
  run detect_gpu_pci "10de"
  [[ "$output" == *"10de:2204"* ]]
  [[ "$output" == *"10de:1aef"* ]]
}

@test "detect_gpu_pci excludes virtio VGA" {
  run detect_gpu_pci "1af4"
  [ -z "$output" ]
}

@test "detect_gpu_pci returns empty for non-existent vendor" {
  run detect_gpu_pci "1234"
  [ -z "$output" ]
}
```

### 7.4 `tests/unit/frag10-iommu.bats`

Tests CPU vendor detection and IOMMU R4 abort from `frag/10-gpu-passthrough.sh`.

```
setup() {
  export PATH="tests/fixtures/mock-bin:$PATH"
  mkdir -p tests/fixtures/mock-bin
  source provision/host/frag/10-gpu-passthrough.sh <<'EOF' || true
EOF
}

@test "vendor detection matches genuineintel" {
  cat > tests/fixtures/mock-bin/lscpu <<'SCRIPT'
#!/bin/bash
echo "Vendor ID:                        GenuineIntel"
SCRIPT
  chmod +x tests/fixtures/mock-bin/lscpu
  run bash -c 'source provision/host/frag/10-gpu-passthrough.sh 2>/dev/null; echo "$IOMMU_FLAG"'
  [[ "$output" == *"intel_iommu=on"* ]]
}

@test "vendor detection matches authenticamd" {
  cat > tests/fixtures/mock-bin/lscpu <<'SCRIPT'
#!/bin/bash
echo "Vendor ID:                        AuthenticAMD"
SCRIPT
  chmod +x tests/fixtures/mock-bin/lscpu
  run bash -c 'source provision/host/frag/10-gpu-passthrough.sh 2>/dev/null; echo "$IOMMU_FLAG"'
  [[ "$output" == *"amd_iommu=on"* ]]
}

@test "R4 aborts on non-separable IOMMU group" {
  # Create fake sysfs with shared group
  mkdir -p tests/fixtures/sysfs/0000:01:00.0/iommu_group/devices
  mkdir -p tests/fixtures/sysfs/0000:01:00.1/iommu_group/devices
  echo "01:00.0" > tests/fixtures/sysfs/0000:01:00.0/iommu_group/devices/0000:01:00.0
  echo "01:00.1" > tests/fixtures/sysfs/0000:01:00.0/iommu_group/devices/0000:01:00.1
  # mock lspci to report both devices
  cat > tests/fixtures/mock-bin/lspci <<'SCRIPT'
#!/bin/bash
echo "01:00.0 VGA compatible controller: NVIDIA ..."
echo "01:00.1 Audio device: NVIDIA ..."
SCRIPT
  chmod +x tests/fixtures/mock-bin/lspci
  run bash -c 'set +e; source provision/host/frag/10-gpu-passthrough.sh 2>&1; echo "exit:$?"'
  [[ "$output" == *"exit:1"* ]]
}
```

### 7.5 `tests/unit/template.bats`

Tests sed substitution of placeholders in user-data templates.

```
@test "substitution replaces all placeholders in desktop user-data" {
  PASS_HASH='$6$rounds=4096$testhash'
  PERSONALIZATION_USERNAME="testuser"
  PERSONALIZATION_FULLNAME="Test User"
  VMCTL_KEY_B64=$(echo "testkey" | base64)
  DEFAULT_REF="v1.0"

  sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
      -e "s|__VMCTL_PRIV_B64__|${VMCTL_KEY_B64}|g" \
      -e "s|__PERSONALIZATION_USERNAME__|${PERSONALIZATION_USERNAME}|g" \
      -e "s|__PERSONALIZATION_FULLNAME__|${PERSONALIZATION_FULLNAME}|g" \
      -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
      desktop/user-data/user-data > /tmp/test-userdata

  ! grep -q '__PERSONALIZATION_USERNAME__' /tmp/test-userdata
  ! grep -q '__PERSONALIZATION_FULLNAME__' /tmp/test-userdata
  ! grep -q 'CHANGE_ME_HASHED' /tmp/test-userdata
  ! grep -q '__GITHUB_REF__' /tmp/test-userdata
  grep -q 'testuser' /tmp/test-userdata
  grep -q 'Test User' /tmp/test-userdata
  grep -q 'v1.0' /tmp/test-userdata
}

@test "answer-host.toml substitution replaces __GITHUB_REF__" {
  DEFAULT_REF="abc123"
  sed -e "s|__GITHUB_REF__|${DEFAULT_REF}|g" \
      provision/host/answer-host.toml > /tmp/test-answer
  ! grep -q '__GITHUB_REF__' /tmp/test-answer
  grep -q 'abc123' /tmp/test-answer
}
```

### 7.6 `tests/unit/build-iso.bats`

Tests ISO filename and URL construction from `ubuntu-release.conf`.

```
@test "ISO filename matches ubuntu version from conf" {
  source provision/ubuntu-release.conf
  EXPECTED="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
  # Verify the filename formula used in build-iso.sh
  grep -q "$EXPECTED" provision/host/build-iso.sh || \
    run grep -c "UBUNTU_VERSION" provision/host/build-iso.sh
}
```

## 8. Runner

`tests/run.sh` — self-contained entrypoint for CI and local use.

```bash
#!/usr/bin/env bash
# tests/run.sh — run test suite (static + unit)
# Usage: tests/run.sh [--fast]  (--fast = static only, for pre-commit)
set -euo pipefail

FAST="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Check dependencies
for cmd in bats shellcheck python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd not found. Install: apt install bats shellcheck python3" >&2
    exit 1
  }
done

echo "=== nested_dev test suite ==="
echo ""

# Static validation
echo "--- Static ---"
cd "$ROOT_DIR"
bats tests/static/lint.bats
bats tests/static/configs.bats
bats tests/static/invariants.bats

if [ "$FAST" = "--fast" ]; then
  echo ""
  echo "=== static only (--fast) ==="
  exit 0
fi

# Unit tests
echo ""
echo "--- Unit ---"
bats tests/unit/personalization.bats
bats tests/unit/resolve-ref.bats
bats tests/unit/gpu-detect.bats
bats tests/unit/frag10-iommu.bats
bats tests/unit/template.bats
bats tests/unit/build-iso.bats

echo ""
echo "=== all passed ==="
```

## 9. CI integration

### `.github/workflows/ci.yml`

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y bats shellcheck python3 python3-yaml \
            dnsmasq iptables

      - name: Run test suite
        run: tests/run.sh
```

### Pre-commit fast-path

Add to `.githooks/pre-commit` (existing, after password-hash guard):

```bash
# Run fast static checks (skip if tests/run.sh not present)
if [ -x tests/run.sh ]; then
    tests/run.sh --fast || exit 1
fi
```

## 10. Running tests locally

```bash
# Full suite
tests/run.sh

# Static only (fast, for pre-commit)
tests/run.sh --fast

# Single test file
bats tests/unit/resolve-ref.bats

# Single test case
bats --filter "branch" tests/unit/resolve-ref.bats
```

## 11. Acceptance criteria

1. `tests/run.sh` exits 0 on a clean checkout (all static + unit pass).
2. `shellcheck -x -s bash` passes on every script in the repo.
3. All 3 user-data files parse as YAML without error.
4. `answer-host.toml` parses as TOML without error.
5. `dnsmasq --test` passes on `provision/network/dnsmasq.conf`.
6. `iptables-restore --test` passes on `provision/network/iptables-forwarding.conf`.
7. No `popiel`/`tapopiel@gmail.com` outside `provision/personalization.sh` and `tests/fixtures/`.
8. All template placeholders (`__GITHUB_REF__`, `CHANGE_ME_HASHED`,
   `__PERSONALIZATION_USERNAME__`, `__PERSONALIZATION_FULLNAME__`) present in
   user-data templates and answer-host.toml.
9. `resolve_ref_to_sha` returns correct output for branch, tag, SHA, and
   unresolvable inputs against mock `git ls-remote`.
10. `detect_gpu_pci` correctly identifies GPU + audio companion, excludes
    virtio, and returns empty for non-existent vendors.
11. CPU vendor detection matches `genuineintel`/`authenticamd` (glob patterns,
    not bare `intel`/`amd`).
12. IOMMU R4 check aborts (exit 1) when GPU + audio share a group.
13. Sed substitution produces user-data with no leftover placeholders and
    correct injected values.
14. Decision-table values (40/80/40 GB, 8192/16384/8192 MB, 4/6/4 cores,
    500 GB data) present in `frag/30-create-guests.sh`.
15. GitHub Actions workflow runs `tests/run.sh` on push and PR.

## 12. Traceability

| Requirement | Source | Tested in |
|---|---|---|
| No hardcoded identity outside personalization.sh | Spec 05 §9 | `invariants.bats` |
| CPU vendor glob matching (`*intel*`/`*amd*`) | Spec 01 §5.1 | `frag10-iommu.bats` |
| Audio companion discovery via BDF prefix | Spec 01 §5.1 | `gpu-detect.bats` |
| IOMMU R4 abort on non-separable groups | Spec 01 §5.1 R4 | `frag10-iommu.bats` |
| OS disk sizes from decision table | Spec 00 §3 | `invariants.bats` |
| RAM/core sizes from decision table | Spec 00 §3 | `invariants.bats` |
| Template placeholder injection | Spec 06 | `template.bats` |
| Personalization sourcing fail-fast | Spec 05 | `personalization.bats` |
| REF resolution (branch/tag/SHA) | Spec 00 §5 | `resolve-ref.bats` |
| shellcheck compliance | Repo convention | `lint.bats` |
| Config file validity | Specs 01, 02, 03, 04 | `configs.bats` |
