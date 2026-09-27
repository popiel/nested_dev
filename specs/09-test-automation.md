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
    helpers.bash            # mock helpers, assert_contains(), assert_file_contains(),
                            # assert_file_matches(), install_mock()
  fixtures/
    mock-lspci.sh           # stand-in for lspci(8), driven by LSPCI_TABLE + LSPCI_FIXTURE_PATH
    lspci-multi-gpu.txt     # NVIDIA GPU + audio companion + Intel iGPU + virtio VGA
    lspci-single-gpu.txt    # single GPU, no audio companion
    lspci-no-gpu.txt        # no GPU (only virtio VGA)
    ubuntu-release.conf     # test copy: 26.04 / noble
  static/
    lint.bats               # shellcheck all scripts; /bin/sh parse; source-guard presence
    configs.bats            # YAML, TOML, dnsmasq, iptables parse validation
    invariants.bats         # identity, placeholder, credential-split, decision-table invariants
  unit/
    personalization.bats    # sourcing contract of provision/personalization.sh
    resolve-ref.bats        # resolve_ref_to_sha: branch, tag, SHA, empty, no-git, git-failure
    gpu-detect.bats         # detect_gpu_pci: multi-GPU, non-matching vendor, virtio passthrough
    frag10-iommu.bats       # CPU vendor → IOMMU flag, audio companion, virtio exclusion, R4 rule
    build-iso.bats          # pure functions, placeholder substitution, credential split
    first-boot-user.bats    # host account creation, credential split, guest root lock
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
| `resolve_ref_to_sha` | `personalization.sh` | Resolves branch/tag/SHA via `git ls-remote`; never fails | `git` (canned output) or no `git` at all |
| `detect_gpu_pci` | `frag/30` | Reads `lspci` + `/sys/bus/pci/devices/*/iommu_group/devices` | `lspci` (reads fixture) |
| `download_iso` | `build-iso.sh` | Downloads ISO with SHA256 verify | `wget` (no-op), `sha256sum` (known hash) |
| `detect_cpu_vendor` | `frag/10` | Reads `lscpu` Vendor ID, lowercases it | `lscpu` (fixture) |
| `iommu_flag_for_vendor` | `frag/10` | Maps the vendor to `intel_iommu=on` / `amd_iommu=on`; returns 1 otherwise | none |
| `iommu_group_device_count` | `frag/10` | Counts devices in a group directory; 0 when absent | temp dir |
| `iommu_group_is_separable` | `frag/10` | The R4 rule: ≤1 device | temp dir |
| `collect_gpu_ids` | `frag/10` | Collects passthrough candidates, excluding virtio `1af4` | `lspci` (fixture) |
| `find_audio_companion` | `frag/10` | Scans same-bus devices via `lspci -s <prefix>.` | `lspci` (fixture) |

`resolve_ref_to_sha` lives in `provision/personalization.sh` only. frag/30
sources that file and calls it. A second copy is what let the two versions
drift apart into a state where frag/30's would abort a `set -euo pipefail`
provisioning run when `git` was missing or the network failed.

### 5.2 Side-effecting logic (static-only or integration-test)

Everything else: `qm create/start/set`, `iptables`/`ip` commands, `apt-get`,
`systemctl`, `genisoimage`, `update-grub`, `update-initramfs`, Docker pulls/runs.

### 5.3 Fixture format

`tests/fixtures/lspci-multi-gpu.txt` — one device per line, matching the
format of `lspci | grep -iE 'vga|3d|display' | awk '{print $1, $0}'`:

```
01:00.0 VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3090] (rev a1)
01:00.1 Audio device: NVIDIA Corporation GA102 HDMI Audio (rev a1)
00:02.0 VGA compatible controller: Intel Corporation Coffee Lake-S GT2 [UHD Graphics 630] (rev 05)
04:00.0 VGA compatible controller: Red Hat, Inc. Virtio GPU (rev 01)
```

`tests/fixtures/mock-lspci.sh` — installed as `lspci` on the mock PATH and
driven by two variables, so one script serves every test that needs PCI data:

- `LSPCI_FIXTURE_PATH` — fixture used for full listings and bus-scoped queries
- `LSPCI_TABLE` — space-separated `<bdf>=<vendor:device>` pairs answering
  `lspci -n -s <bdf>`

IOMMU groups are **not** faked with a fixture file. The rule counts directory
entries under `/sys/bus/pci/devices/<BDF>/iommu_group/devices`, so the tests
create a temp directory with one file per device and pass its path to
`iommu_group_is_separable`. A fixture of `lspci` output cannot express it, which
is why the two tests that claimed to cover the R4 abort did not.

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

@test "every sourced-later script has a source-guard" { ... }

@test "sh scripts parse under /bin/sh" { ... }
```

The `sh` test exists because `first-boot.sh` and `provision-host.sh` run on a
stock Debian PVE host where `/bin/sh` is dash, while the lint tier only ever
checked them with `shellcheck -s bash`. A bashism there fails at provisioning
time on the one host that matters. It skips when `dash` is not installed.

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
  # filter out personalization.sh and the test tree
  filtered=$(echo "$output" | grep -v 'provision/personalization.sh' | grep -v '/tests/' || true)
  [ -z "$filtered" ]
}

@test "no hardcoded tapopiel@gmail.com outside personalization.sh" {
  run grep -r 'tapopiel@gmail.com' --include='*.sh' --include='*.toml' .
  filtered=$(echo "$output" | grep -v 'provision/personalization.sh' | grep -v '/tests/' || true)
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

@test "host templates carry the placeholders their renderer substitutes" {
  for entry in \
    "provision/host/answer-host.toml|__GITHUB_REF__" \
    "provision/host/answer-host.toml|__ROOT_SSH_KEY__" \
    "provision/host/answer-host.toml|__ROOT_PASSWORD_HASH__" \
    "provision/host/first-boot.sh|__PERSONALIZATION_PASSWORD_HASH__" \
  ; do
    grep -q "${entry##*|}" "${entry%%|*}"
  done
}

# --- Credential split (Spec 05 §5) ---
# These are the tests that would catch the two hashes being swapped, merged
# back into one file, or renamed out from under first-boot.sh / frag/30. The
# failure mode they prevent is silent and late: nothing breaks at build time,
# the host just ends up with a root password where the operator expected a
# login password (or the reverse) after a reinstall.
#
# Which carrier receives which hash is asserted on the *rendered* output in
# tests/unit/build-iso.bats, not by matching placeholder names here.

@test "first-boot.sh carries no root password hash" {
  ! grep -q '__ROOT_PASSWORD_HASH__' provision/host/first-boot.sh
}

@test "no committed host template carries a real password hash" {
  # CHANGE_ME_HASHED and the __PLACEHOLDER__ names are not hashes; a real one
  # starting $6$/$y$/$5$ in a committed file means a leak.
  for f in provision/host/answer-host.toml provision/host/first-boot.sh; do
    ! grep -qE '\$(6|y|5)\$[A-Za-z0-9./]+' "$f"
  done
}

@test "neither password hash is tracked by git" {
  for f in keys/root-password-hash keys/personalization-password-hash; do
    ! git ls-files --error-unmatch "$f" 2>/dev/null
  done
}

@test "the stale password-hash names are referenced nowhere in the source tree" {
  # Scoped to the source tree and operator docs: this file and
  # first-boot-user.bats necessarily name the old paths in negative
  # assertions, and this spec quotes them in documenting the rename.
  for dir in provision desktop llm dev; do
    run grep -rn 'keys/password-hash\|/root/\.password-hash' "$dir"
    [ -z "$output" ]
  done
}

@test "frag/30 sources personalization.sh from correct path" {
  grep -q '\. /root/provision/personalization\.sh' provision/host/frag/30-create-guests.sh
}

@test "frag/30 aborts when personalization vars are empty" {
  # The specific guard, not a bare `exit 1` somewhere in a 400-line script.
  grep -q 'PERSONALIZATION_USERNAME or PERSONALIZATION_FULLNAME not set' \
    provision/host/frag/30-create-guests.sh
  grep -q 'Personalization password hash not found' \
    provision/host/frag/30-create-guests.sh
}
```

## 7. Unit test suite

### 7.1 `tests/unit/personalization.bats`

Asserts the *contract* of `provision/personalization.sh`, not its concrete
values. The identity is the fork owner's to change (§ Spec 05), so no test may
hardcode a username, name, email or UID — the previous version of this file
asserted eight fixture values, which tested the fixture rather than the repo.

```
setup_personalization() {
  local var
  for var in "${REQUIRED_VARS[@]}"; do export "$var"=""; done
  source provision/personalization.sh
}

@test "sourcing personalization.sh defines every required variable" { ... }
@test "PERSONALIZATION_HOME derives from PERSONALIZATION_USERNAME" { ... }
@test "resolve_ref_to_sha is defined in exactly one script" { ... }
```

`TARGET_DISKS` is excluded from the required set: it is build-host-specific and
empty by design.

### 7.2 `tests/unit/resolve-ref.bats`

Tests `resolve_ref_to_sha` from `provision/personalization.sh` with mocked
`git`. The last two cases are the contract frag/30's private copy violated: the
function must return successfully and print an empty string when `git` is absent
or fails, because its callers run under `set -euo pipefail` and a non-zero
return there aborts provisioning mid-flight.

| Case | Expectation |
|---|---|
| branch | SHA from `refs/heads/` |
| tag | SHA from `refs/tags/`, after the branch lookup returns nothing |
| same name for both | the branch wins |
| 40-hex input | passed through unchanged, no `git` call |
| unresolvable ref | empty string |
| no `git` on PATH | exit 0, empty string |
| `git` exits 128 | exit 0, caller continues |

### 7.3 `tests/unit/gpu-detect.bats`

Tests `detect_gpu_pci` from `frag/30-create-guests.sh` using the shared
`tests/fixtures/mock-lspci.sh`, configured per test through `LSPCI_TABLE` and
`LSPCI_FIXTURE_PATH`.

Note the division of labour: `detect_gpu_pci` filters on whatever vendor it is
handed and will happily return a virtio device. Excluding virtio is
`collect_gpu_ids`' job in frag/10, and that is where the exclusion is tested
(§7.4). Neither function should grow the other's rule.

### 7.4 `tests/unit/frag10-iommu.bats`

Tests the frag/10 helpers directly, which is only possible because each one
takes the data it needs as an argument rather than reading a hardcoded path.

| Group | Function | Covers |
|---|---|---|
| CPU vendor | `detect_cpu_vendor` | lowercases the `lscpu` Vendor ID; empty when absent |
| | `iommu_flag_for_vendor` | `genuineintel` → `intel_iommu=on`, `authenticamd` → `amd_iommu=on`, anything else → non-zero so the caller aborts rather than booting with IOMMU silently off |
| Passthrough set | `collect_gpu_ids` | excludes virtio `1af4`; returns an empty set on a host whose only GPU is virtio |
| Audio | `find_audio_companion` | BDF of the audio function; empty when the GPU has none |
| IOMMU R4 | `iommu_group_device_count` | 0 / 1 / 2 devices; 0 for a group that does not exist |
| | `iommu_group_is_separable` | 1 device → separable; 2 or 3 → not separable |
| | `check_iommu_group_separable` | maps a BDF to `/sys/bus/pci/devices/0000:<BDF>/iommu_group/devices` |

The R4 rule is stated in exactly one place in the source, `iommu_group_is_separable`,
and `main()` calls it for both the GPU and the audio function rather than
re-deriving the group size. A test asserts that wiring, because the previous
version of this file asserted R4 coverage with two tests that created a temp
directory, counted its own files, and never called the function they were named
after — the rule had no coverage while the spec claimed it did.

### 7.5 `tests/unit/build-iso.bats`

Sources `build-iso.sh` through the source-guard and tests `render_template`,
`generate_answer_file`, `generate_first_boot_script`,
`validate_target_disks` and the MANIFEST writer.

ISO filename and URL construction comes from `ubuntu-release.conf`. Template
rendering is covered in five groups:

| Group | Asserts |
|---|---|
| Disk validation | quoted/unquoted/bracketed lists normalize to exactly the requested entries and nothing else; `/dev/` paths, partition names, empty and multi-disk lists are rejected at build time, so a bad `PERSONALIZATION_TARGET_DISKS` fails before the 1.7 GB ISO step |
| Escaping | a yescrypt hash survives `sed` (unescaped `$y$…` expands to nothing and silently produces an install with no working credentials); the same for the login hash, the email and the SSH key |
| Two hashes, two destinations | the rendered answer file receives only the root hash and the rendered bootstrap only the login hash — swapping the two positionals would compile, validate, install, and hand out a host whose root password is the login password |
| No leftovers | neither the answer file nor the **bootstrap** retains any `__PLACEHOLDER__`. The bootstrap was previously unchecked: a now-removed test file re-implemented the `sed` pipeline inline instead of calling `render_template`, so it proved `sed` works, not that the shipped bootstrap is complete |
| Un-sourced identity | an unset `PERSONALIZATION_*` leaves its `__PLACEHOLDER__` in the output so the build's guard fires. The answer file can only show the email; the username, UID, GID and home show up in the bootstrap, since PVE's schema has no non-root user field for them |

There is also a **no-orphan-function** test: every function defined in
`build-iso.sh` must be called somewhere else. It replaces three "function
exists" greps, which could only ever fail if a definition was deleted, never if
a call site was renamed away or a helper was left behind.

Carrier assertions pin `source = "from-iso"` (never `from-url`), the absence
of any `late-commands` section, and that the bootstrap reaches
`prepare-iso --on-first-boot` in both the `pve-auto-install-assistant` and
`proxmox-auto-install-assistant` call sites.

```
@test "ISO filename matches ubuntu version from conf" {
  source provision/ubuntu-release.conf
  EXPECTED="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
  # Verify the filename formula used in build-iso.sh
  grep -q "$EXPECTED" provision/host/build-iso.sh || \
    run grep -c "UBUNTU_VERSION" provision/host/build-iso.sh
}
```

### 7.7 `tests/unit/first-boot-user.bats`

Covers the host-side account creation and the credential split (Spec 05 §4.1,
§5). `first-boot.sh` is a boot-time script on a machine the test suite cannot
reach, so these are source assertions on the rendered shape of the script —
the same style as `frag10-iommu.bats` (§7.4). Each test states the failure it
prevents.

| Test group | Asserts |
|---|---|
| Hash split (D4) | `build-iso.sh` reads `keys/root-password-hash` and `keys/personalization-password-hash`; each missing file produces its own named error; the answer file takes the root hash while the bootstrap takes the login hash; the bootstrap applies only the login hash to the account and never creates or re-credentials `root` |
| Identity | `useradd` uses the configured UID, GID, home and `/bin/bash`; the GECOS field carries `${PERSONALIZATION_FULLNAME}`, not the username |
| Idempotency | Re-running the block is a no-op; it refuses to proceed if the UID or GID already belongs to a *different* account rather than silently creating a second identity for one operator |
| Privileges | `usermod -aG sudo`; `authorized_keys` holds the operator public key |
| Modes | `~/.ssh` 700, `authorized_keys` 600, home `chown`ed to the account |
| Ordering | Account creation precedes the provision-tree fetch, so a failed fetch still leaves a usable operator login |
| Rename (D5) | The persisted path is `/root/.personalization-password-hash` and `/root/.password-hash` is gone; `frag/30` reads exactly the same path; the file is 600 |
| Guest root | Every seed runs `passwd -l root`, and no seed does anything else to root |
| Dev tooling | `dev/tools/nested keys-status` reports on both hashes |

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
bats tests/unit/frag25-vmctl.bats
bats tests/unit/first-boot-user.bats
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

Add to `.githooks/pre-commit` (existing, after the user-data hash guard):

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
3. The `#!/bin/sh` scripts parse under `dash`.
4. Every script a test sources has a `BASH_SOURCE` source-guard.
5. All 3 user-data files parse as YAML without error.
6. The rendered `answer-host.toml` parses as TOML without error.
7. `dnsmasq --test` passes on `provision/network/dnsmasq.conf`.
8. `iptables-restore --test` passes on `provision/network/iptables-forwarding.conf`.
9. No `popiel`/`tapopiel@gmail.com` outside `provision/personalization.sh`.
10. All template placeholders (`__GITHUB_REF__`, `CHANGE_ME_HASHED`,
    `__PERSONALIZATION_USERNAME__`, `__PERSONALIZATION_FULLNAME__`) present in
    user-data templates and answer-host.toml.
11. `resolve_ref_to_sha` returns correct output for branch, tag, SHA, and
    unresolvable inputs against mock `git ls-remote`, and exits 0 without
    raising when `git` is absent or fails.
12. `resolve_ref_to_sha` is defined in exactly one script.
13. `detect_gpu_pci` returns the matching GPU, returns empty for a vendor that
    is not present, and excludes the non-matching vendor on a mixed-GPU host.
14. `collect_gpu_ids` excludes the virtio GPU.
15. `iommu_flag_for_vendor` maps `genuineintel`/`authenticamd` to
    `intel_iommu=on`/`amd_iommu=on` and fails for any other vendor.
16. IOMMU R4: a group of one device is separable; two or more is not, and
    `main()` enforces it through the shared rule.
17. `render_template` leaves no `__PLACEHOLDER__` in the rendered answer file
    **or** the rendered bootstrap, and injects the expected values.
18. Decision-table values (40/80/40 GB, 8192/16384/8192 MB, 4/6/4 cores,
    500 GB data) present in `frag/30-create-guests.sh`.
19. GitHub Actions workflow runs `tests/run.sh` on push and PR.
20. `keys/root-password-hash` and `keys/personalization-password-hash` are
    both required by `build-iso.sh`, neither is git-tracked, and no committed
    template contains a real hash.
21. The rendered answer file carries the root hash and the rendered bootstrap
    the login hash — never each other's.
22. The host account is created with the configured UID/GID/home/shell, `sudo`
    membership, the operator key, and the login hash, and is never given the
    root hash.
23. All three guest seeds run `passwd -l root` and do nothing else to root.
24. No function in `build-iso.sh` is defined but never called.

## 12. Traceability

| Requirement | Source | Tested in |
|---|---|---|
| No hardcoded identity outside personalization.sh | Spec 05 §9 | `invariants.bats` |
| CPU vendor glob mapping to the IOMMU flag | Spec 01 §5.1 | `frag10-iommu.bats` |
| Audio companion discovery via BDF prefix | Spec 01 §5.1 | `frag10-iommu.bats` |
| IOMMU R4 abort on non-separable groups | Spec 01 §5.1 R4 | `frag10-iommu.bats` |
| Virtio GPU excluded from passthrough | Spec 01 §5.1 | `frag10-iommu.bats` |
| OS disk sizes from decision table | Spec 00 §3 | `invariants.bats` |
| RAM/core sizes from decision table | Spec 00 §3 | `invariants.bats` |
| Template placeholder injection, no leftovers | Spec 06 | `build-iso.bats` |
| Personalization sourcing contract | Spec 05 | `personalization.bats` |
| REF resolution (branch/tag/SHA/empty/no-git) | Spec 00 §5 | `resolve-ref.bats` |
| Single definition of `resolve_ref_to_sha` | Spec 05 §5.2 | `personalization.bats` |
| shellcheck compliance, `/bin/sh` parse, source-guards | Repo convention | `lint.bats` |
| Config file validity | Specs 01, 02, 03, 04 | `configs.bats` |
| Two separate hash files, neither tracked | Spec 05 §5, Spec 01 §4.3 | `invariants.bats`, `first-boot-user.bats` |
| Root hash reaches only the answer file | Spec 01 §4.3 | `build-iso.bats` (rendered output) |
| Host account identity, sudo, key, modes | Spec 05 §4.1 | `first-boot-user.bats` |
| Account created before the provision fetch | Spec 01 §4.1 | `first-boot-user.bats` |
| `/root/.personalization-password-hash` rename, agreed by both sides | Spec 05 §5.2 | `first-boot-user.bats` |
| Guest root locked, and only locked | Spec 05 §5.4 | `first-boot-user.bats` |
| Dev VM reports on both hashes | Spec 08 | `first-boot-user.bats` |
| No dead functions in the build script | Repo convention | `build-iso.bats` |
