# AGENTS.md — working notes for coding agents on this repository

Read this before running the test suite. The obvious command is roughly 50× too
slow on Windows, and it fails in a way that looks like a hang.

## How to run the tests

**On Windows, always use the WSL wrapper:**

```bash
bash tests/run-wsl.sh                    # whole suite
bash tests/run-wsl.sh --fast             # static only (lint, configs, invariants)
bash tests/run-wsl.sh tests/unit/gpu-detect.bats
bash tests/run-wsl.sh tests/unit/frag10-iommu.bats tests/unit/frag25-vmctl.bats
bash tests/run-wsl.sh --slowest 20       # longer slow-test table
```

**On Linux or macOS, use `tests/run.sh` directly** — the same flags work:

```bash
bash tests/run.sh
bash tests/run.sh --fast
bash tests/run.sh tests/unit/gpu-detect.bats
```

Both exit non-zero when any test fails.

### Do not run `bats` directly, and do not run `tests/run.sh` from git-bash or PowerShell

Under git-bash/MSYS every process spawn costs about 65ms, and `bats` forks
several times per test. Measured on this machine:

| | 30-test `--fast` subset | full 248-test suite |
|---|---|---|
| git-bash / MSYS | ~4 min | ~15 min, exceeds a 10 min tool timeout |
| WSL2, repo on `/mnt/c` | 13s | 34s |

The suite does finish under MSYS, but it takes long enough that a tool timeout
kills it first. If a test command is about to be launched from an MSYS shell,
use `bash tests/run-wsl.sh` instead.

WAL is about a quarter of the WSL run: the report attributes most of the
remainder to harness time, not to test bodies. Optimising an individual test
will not move that number.

Bypassing the entry points also loses the timing record and the per-test
failure diagnostics, so the result is not equivalent even where it is fast.

### One-time WSL setup

The wrapper needs `bats` and `shellcheck` as **native Linux** binaries. Install
them without `sudo`:

```bash
bash tests/run-wsl.sh --setup
```

That clones bats-core and unpacks the shellcheck release into `~/bin`. The
wrapper refuses to run if the tools resolve to Windows binaries over `/mnt/c`,
because that silently reintroduces the slow path.

The distro is auto-detected; override it with
`bash tests/run-wsl.sh --distro Ubuntu-24.04`.

## Reading the results

`tests/run.sh` prints, in order:

1. one line per suite: pass/fail, test counts, suite wall time, time inside tests
2. the full TAP output of any suite that failed, including the assertion
3. a `=== timing ===` report
4. a `=== result ===` block of `key=value` pairs — this is what the wrapper
   parses for its own summary, so do not rename those keys

A failing suite is printed in full. Do not go looking for a separate log.

## Test timing records

Every run leaves a per-test record under `tests/.timing/` (gitignored):

```bash
bash tests/timing.sh report      # slowest tests, harness overhead, regressions
bash tests/timing.sh slowest 20  # just the slow table
bash tests/timing.sh history     # one row per run, newest first
```

The report separates two costs, because on Windows they differ by two orders of
magnitude:

- **in tests** — time inside test bodies, the part the tests control
- **harness** — wall time not attributed to any test body: `bats`' own per-test
  process setup plus the fixed startup of each `bats` process

If `harness` is the large number, optimising an individual test will not help;
reduce the number of tests, or run the suite in a faster environment. Only treat
a change in **in tests** as a real performance regression.

Records accumulate across runs, so `report` compares each run against the one
before it and lists tests that got meaningfully slower (both ≥50% and ≥100ms, to
keep sub-20ms jitter from looking like a regression). Pass
`--regression-pct` / `--regression-min-ms` to change those thresholds.

`tests/.timing/` is gitignored on purpose: it is per-machine measurement, not
source.

## Adding a test

1. Put the file in `tests/static/` or `tests/unit/`.
2. `load '../lib/helpers'` at the top for the shared assertions.
3. **Add it to the suite list in `tests/run.sh`** (`ALL_SUITES`, and
   `STATIC_SUITES` if it is static). A `.bats` file that `run.sh` does not name
   is never executed, and `tests/unit/timing.bats` fails if that happens.
4. Add a regression test for every bug fixed, in the suite that owns the area.

A new test should assert behaviour, not wording. Two real cases in this
repository:

- `tests/unit/build-iso.bats` used to assert the literal sentence
  ``No `late-commands` `` in `specs/01`. Rewriting the spec into behaviour-focused
  requirements broke a test even though the requirement was still there. Assert
  the substance — that a prohibition is stated, that the supported mechanism is
  named — not one sentence.
- `tests/unit/resolve-ref.bats` simulated "git is not installed" by setting
  `PATH=...:/usr/bin:/bin`. On any real Linux host git *is* in `/usr/bin`, so the
  test quietly reached the network. It passed only on git-bash, where git lives
  in `/mingw64/bin`. Simulate absence hermetically, and assert the precondition
  so a broken simulation reports as a broken test.

Avoid tests that depend on the host's PATH contents, on the presence of
optional tools (`dnsmasq`, `iptables-restore`, `hadolint`), or on network
access. `tests/static/configs.bats` skips its optional checks when those tools
are absent, and that is expected.

## Shell portability

Scripts run on a Debian-based PVE host, in Ubuntu guests, and in the test suite
on Linux and WSL. The test suite also runs under git-bash on Windows, so:

- `tests/lib/helpers.bash` converts paths for native Windows binaries with
  `win_path`; use it when handing a path to `python3` or another native tool.
- Guard anything that only exists on one platform, e.g.
  `command -v cygpath >/dev/null 2>&1`.
- When passing a path from Windows into WSL, use forward slashes. `wsl.exe`
  hands the argument to the Linux command through the Windows command line,
  where backslashes are consumed as escapes, so `C:\Users\x` arrives as
  `C:Usersx`. `tests/run-wsl.sh` uses `cygpath -m` for this reason.

## Repository map

| Path | What it is |
|---|---|
| `specs/00`–`09` | Behaviour-focused requirements. Normative outcomes, not HOWTOs. |
| `provision/host/` | Hypervisor host: PVE ISO build, first-boot, firewall, guest creation. |
| `provision/network/` | Reference firewall ruleset. |
| `provision/personalization.sh` | Canonical identity, target disk, repo, release ref. |
| `desktop/`, `llm/`, `dev/` | Per-guest cloud-init seeds and the desktop control CLI. |
| `tests/run.sh` | Suite entry point. Accepts `--fast` and explicit files. |
| `tests/run-wsl.sh` | Windows-side wrapper that runs the suite inside WSL. |
| `tests/wsl-setup.sh` | User-space `bats` + `shellcheck` install for WSL. |
| `tests/timing.sh` | Parses `bats -T` output into per-test records; prints reports. |
| `tests/lib/helpers.bash` | Shared assertions and mock helpers. |

`tests/lib/helpers.bash` is loaded by every test file and must stay tracked. A
stray unanchored `lib/` in `.gitignore` once excluded it, which would leave a
fresh clone unable to run any test.
