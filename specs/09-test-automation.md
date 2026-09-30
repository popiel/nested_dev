# Spec 09 — Test automation

Status: Draft
Applies to: everything in this repository
Implementation: `tests/run.sh`, `tests/run-wsl.sh`, `tests/wsl-setup.sh`,
`tests/timing.sh`, `tests/static/`, `tests/unit/`, `tests/lib/`,
`tests/fixtures/`, `.pre-commit-config.yaml`

## 1. Scope

What the test suite guarantees, how it is organised, and — as important — what
it deliberately does not cover.

In scope: test layers, required and optional tooling, the coverage each spec's
requirements map to, test conventions, and the known coverage gaps. Out of
scope: end-to-end fleet behaviour on real hardware, which is verified by the
acceptance tables in each spec.

## 2. Decisions

| Aspect | Choice |
|---|---|
| Framework | `bats` |
| Entry point | One script runs everything; a fast mode runs the static layer only |
| Windows entry point | A wrapper runs the same suite inside WSL, because MSYS process emulation makes it roughly two orders of magnitude slower |
| Layers | Static (lint, config, invariants) and unit (functions and files) |
| Style | Assertions read the repository's own files; a pure function is invoked and checked |
| Speed | No test may require a hypervisor, a network, or a real guest |
| Timing | Every run records per-test duration and separates time inside tests from harness overhead |
| Optional tools | A test whose tool is absent reports a skip, never a pass and never a failure |
| Credentials | Tests never need a real hash or key; they use fixtures |
| Gating | The pre-commit hook runs the fast layer; the full suite runs before a release reference is pinned |

## 3. Requirements

### R-09.1 One command runs everything, and says what it cannot do

* **R-09.1.1** A single entry point runs the static layer and then the unit
  layer, labelling each group as it goes, and exits non-zero if anything fails.
* **R-09.1.2** A fast mode runs the static layer only, for the pre-commit path.
  The static layer is the one that must be green at every commit, because it is
  the only layer fast enough to be.
* **R-09.1.3** The entry point checks its required tools up front and, when one
  is missing, names the tool and the package that provides it. A suite that
  fails with `command not found` halfway through reports a code failure for a
  missing dependency.
* **R-09.1.4** It reports which optional tools are present, so a run that
  skipped a validation is visibly weaker than a run that performed it.
* **R-09.1.5** Nothing in the suite requires a hypervisor, a network
  connection, or a booted guest. A test that did would make the suite
  unrunnable by anyone without the fleet.
* **R-09.1.6** The entry point accepts named test files and runs only those. A
  developer fixing one area must be able to run that area without paying for
  the rest of the suite.
* **R-09.1.7** The entry point prints a machine-readable result block of
  `key=value` pairs, so that a wrapper can report the outcome without parsing
  human-readable prose.
* **R-09.1.8** The block reports passes, failures and skips as three distinct
  counts, and the three sum to the number of tests that ran. A skip is a test
  that did not run, and reporting it as a pass claims coverage the run never
  had.
* **R-09.1.9** The tally is derived independently of the timing record, and the
  two are cross-checked. Two derivations of the same run that disagree mean one
  of them is wrong, and a single source of truth cannot detect its own error.
* **R-09.1.10** A suite that fails before recording any result is reported as
  failed, not as a pass. A tally derived only from per-test lines calls a suite
  that never ran clean, because nothing recorded a failure.
* **R-09.1.11** The entry point always reaches its result block. A problem
  encountered while summarising a suite is reported, and never aborts the run:
  a run's outcome is the one thing that must survive whatever went wrong.

### R-09.1a On Windows the suite runs inside WSL

* **R-09.1a.1** A Windows host runs the suite through a wrapper that executes it
  in WSL, passing the same flags and the same named files. Running the suite
  directly under a POSIX-emulation shell is not supported, because process
  creation there costs enough to make the suite unusable.
* **R-09.1a.2** The wrapper installs its own prerequisites without `sudo`, into
  the invoking user's home directory, and the wrapper detects when they are
  absent and says how to install them.
* **R-09.1a.3** The wrapper refuses to run when the required tools resolve to
  binaries on the Windows filesystem. Those tools would appear to work while
  reintroducing exactly the cost the wrapper exists to avoid.
* **R-09.1a.4** The wrapper propagates the suite's exit status, and reports the
  pass, fail and skip counts and where the timing records were written.
* **R-09.1a.5** Paths are converted to WSL form with forward slashes, because
  the Windows command line consumes backslashes as escapes before the Linux
  command ever sees them.

### R-09.1b The suite list is asserted, not trusted

* **R-09.1b.1** Every test file in the tree is named by the entry point's suite
  list. A `.bats` file the entry point never mentions is never executed, and
  never fails.
* **R-09.1b.2** The suite list is compared against the files on disk as a set,
  not counted. A count can be satisfied by one duplicate entry and one omission
  at the same time.
* **R-09.1b.3** Suite labels are unique, because a label is the key a timing
  record is filed under. Two files sharing one label merge their records, and
  the report then describes a test that does not exist.
* **R-09.1b.4** Every static suite is reachable from the fast mode, so a check
  added to the static layer cannot go unrun by the pre-commit path.
* **R-09.1b.5** A check that enumerates the tree asserts that its enumeration
  found something. An enumeration that silently matches nothing reports
  success, which is the failure mode a coverage check cannot have.

### R-09.2 The static layer asserts properties of the repository

* **R-09.2.1** **Lint.** Every shell script passes `shellcheck`, including the
  extension-less ones, and the extension-less ones are covered explicitly
  because a glob that only matches `*.sh` silently skips the most security
  relevant files in the repository: the control program, the control wrapper,
  and the two tool wrappers.
* **R-09.2.2** **Source guards.** Any script that is both executed and sourced
  carries a guard, so sourcing it for its functions does not run its body.
* **R-09.2.3** **Config validity.** Every guest seed parses as YAML. The
  rendered answer file parses as TOML. The name-service and firewall reference
  files are handed to their own tools, and those checks are skipped — visibly —
  when the tools are absent.
* **R-09.2.4** **Invariants.** Properties that must hold across the whole tree
  are asserted by sweeping the tree, not by checking one file. An invariant that
  is only checked where it is expected to hold is not an invariant.
* **R-09.2.5** Identity values appear in exactly one place. A username, an
  email address and a target disk name are asserted absent from every file
  except the one that defines them.
* **R-09.2.6** Sizes the specs state as decisions are asserted present in the
  code that applies them, for both baselines where a baseline applies.
* **R-09.2.7** Every renderer is paired with an assertion about the placeholders
  it substitutes, in both directions: the templates carry the placeholders the
  renderer replaces, and the renderer is required to consume all of them.
* **R-09.2.8** A policy that is expressed as a comment is also asserted as a
  rule. Where a document says a guest has a particular egress, the firewall
  must contain a rule granting it — otherwise the comment is the only thing
  granting it.

### R-09.3 The unit layer invokes the code

* **R-09.3.1** Pure functions are invoked and their return values checked:
  reference resolution, disk-list validation, template rendering, escaping,
  hash computation, vendor and flag mapping, IOMMU separability, and the
  assistant's error detection.
* **R-09.3.2** Escaping is tested against the characters that actually break a
  substitution: backslash, dollar sign, delimiter, ampersand, and a real
  yescrypt hash. A hash that survives a template render is the difference
  between a working host and a host nobody can log in to.
* **R-09.3.3** A function that can report failure while exiting zero is tested
  for the failure, not only for the success. This is the case where a build
  reports success over a hard error.
* **R-09.3.4** Hardware-dependent functions are tested against recorded
  enumerations, so a two-GPU host, a one-GPU host, a host with no matching
  device and a host with only a fallback device are all exercised without any
  of them present.
* **R-09.3.5** A guard against `set -e` being defeated by command substitution
  is tested directly.
* **R-09.3.6** Dead code is detected: a function defined and never called is a
  test failure. Refactoring leaves these behind, and a function nothing calls
  is either a mistake or a leftover that will be edited as if it were live.
* **R-09.3.7** Where a definition must exist in exactly one place — a shared
  function whose whole value is that two call sites cannot disagree — that is
  asserted.

### R-09.4 Every defect that reached production is now a test

* **R-09.4.1** A defect that was found by inspection gets a test named after
  the defect, and the test's comment states what broke and why the test is not
  obvious. This is the suite's most valuable property: the next person to
  "simplify" the code finds the test that explains why the shape is what it is.
* **R-09.4.2** The named defects, and what each one was:

  | Defect | Failure it produced |
  |---|---|
  | `vmctl` created with a no-login shell | A forced command is run *by* the login shell, so every fleet control verb died with "account not available" |
  | Desktop seed writing keys into a directory that does not exist yet | Key writes failed during the install stage and the error was discarded |
  | Guests with password auth disabled and no authorised keys | No guest was reachable over SSH at all |
  | `vmctl-host` sourced from a path that does not exist in the deployed tree | The control program was never installed; every control verb failed against a missing binary |
  | Dev seed not fetching the tool wrappers the first-boot script installs | Wrappers reported missing on every first boot; the tool wrappers call one of them |
  | Guest fetching its own assets from a branch name rather than its build reference | The template's images and the script that installed them could come from different commits |
  | Clones inheriting the template's hostname | Every dev VM called itself the same name; the registered DNS name never matched |
  | Credential check looking in a directory the build does not read | Working credentials reported missing, and the operator told to create a second, unused copy |
  | Desktop documented as unrestricted with no firewall rule | The bastion had no route off the private bridge |

* **R-09.4.3** A test that documents a defect asserts the *behaviour that
  prevents it*, not the absence of a string. "The path that does not exist is
  not present" is a proxy; "the path resolves to a directory containing the
  file" is the property.

### R-09.5 Credentials and secrets are test fixtures, never real values

* **R-09.5.1** No test requires a real password hash, private key or operator
  key. Tests that need one use a placeholder that cannot authenticate anything.
* **R-09.5.2** The suite asserts that neither credential is tracked by version
  control, and that no committed template carries a real hash.
* **R-09.5.3** The suite asserts that a stale credential *name* is referenced
  nowhere in the tree. A renamed credential that is still read under its old
  name in one place is a build that fails on a machine where the old file
  happens to exist.
* **R-09.5.4** The credential paths used by the build and the credential paths
  used by any operator-facing check are asserted to be the same. Two
  directories for one credential is how a check reports a working setup as
  broken.

### R-09.6 The suite documents its own gaps

* **R-09.6.1** Properties asserted elsewhere are asserted here too where the
  thing being tested lives in a different file. A requirement enforced only in
  the file it names is one refactor away from being unenforced.
* **R-09.6.2** Where a spec states a requirement and no test covers it, this
  spec says so by naming the spec and the requirement. An unstated gap reads as
  a covered one.

### R-09.7 Every run measures itself

* **R-09.7.1** Every suite is invoked in a mode that reports how long each test
  took, and every run leaves a per-test record on disk.
* **R-09.7.2** The record identifies each test by suite and name, not by its
  position, so a test can be compared across runs even when tests are inserted
  above it.
* **R-09.7.3** A report separates **time inside test bodies** from **harness
  time** — the wall time not attributed to any test body, which is the
  framework's own per-test setup plus each invocation's startup. The two differ
  by orders of magnitude on some hosts, and a report that only showed total
  duration would send effort at the wrong target.
* **R-09.7.4** The harness share is reported per suite, so the cost of process
  setup can be distinguished from the cost of the tests themselves.
* **R-09.7.5** Records accumulate across runs, and a report compares each run
  against the previous one, listing tests that became meaningfully slower.
* **R-09.7.6** A slowdown is only reported when it is both relatively and
  absolutely significant. A percentage alone turns ordinary scheduling jitter
  in a very fast test into a large apparent regression, which trains the reader
  to ignore the list.
* **R-09.7.7** A run is not compared against a partial previous run, which would
  make every surviving test look like a regression.
* **R-09.7.8** A result line that carries no measurement — a file-level error,
  for instance — is recorded as unmeasured rather than being reported as fast.
* **R-09.7.9** Timing records are excluded from version control. They are
  per-machine measurement, not source.
* **R-09.7.10** Recording timing never changes the suite's result. A failure in
  the timing tooling is reported as a warning and the suites still run.
* **R-09.7.11** A skipped test's elapsed time is measured and included in the
  suite's total. The skip reason is written after the measurement, so a summary
  that matches the measurement only at end-of-line silently drops every skipped
  test's time and reports a suite as faster than the sum of its own tests.

## 4. Coverage map

| Spec | Test file | Covers |
|---|---|---|
| 00 | `invariants.bats` | Sizing baselines, guest egress policy and its firewall rules, dev range containment |
| 01 | `build-iso.bats` | Disk validation, rendering, escaping, manifest, assistant failure detection, MSYS path handling |
| 01 | `invariants.bats` | Answer-file shape, bootstrap placeholders |
| 01 | `provision.bats` (e2e) | Operator account identity, password hash, `sudo` grant, key installation, no `root` credentialing |
| 01 | `frag10-iommu.bats` | Vendor detection, IOMMU flag mapping, audio companions, separability over fixture groups including the measured host layout, virtio exclusion |
| 01 | `gpu-detect.bats` | Partitioning the accepted passthrough set by role, unknown vendors left out, missing set aborts |
| 01 | `provision.bats` (e2e) | Control account, keypair generation, host trust pin, staged-key destruction |
| 02/03/04 | `configs.bats` | Seed YAML validity |
| 02/03/04 | `invariants.bats` | Placeholder inventory, desktop private-key exclusivity |
| 05 | `personalization.bats` | Variable definition, derived home, single definition of the shared resolver |
| 05 | `resolve-ref.bats` | Branch, tag, SHA pass-through, unresolvable, absent git, `set -e` safety |
| 05 | `guest-seeds.bats` | Locked `root` in every seed, template placeholder vocabulary |
| 05 | `provision.bats` (e2e) | Hash reaches the account and every seed; admin and guest keys injected |
| 06 | `provision.bats` (e2e) | Placeholder survival detection, key injection, staged-key shredding, re-provisioning changes nothing |
| 06 | `guest-seeds.bats` | Template placeholder vocabulary |
| 06 | `invariants.bats` | Placeholder inventory completeness |
| 07 | `control-tools.bats` | Forced-command restriction, real shell, dev range, hostname settling, error text |
| 07 | `provision.bats` (e2e) | Control-program installation, forced-command account as created |
| 08 | `nested-keys-status.bats` | Operator credential check looks in `keys/`, executed against fixture credentials |
| 09 | all | Source guards, lint coverage of extension-less scripts and of the harness itself, dead-code detection |
| 09 | `timing.bats` | Timing record parsing, report totals, regression thresholds, builder-vs-tree set equality, label uniqueness, fast-mode coverage, result-block accounting, skip handling, unrunnable and unparseable suites, wrapper and setup-script contracts, `AGENTS.md` accuracy |

The map names the suite that owns each area, not the tests within it. The set
of suites is asserted against the files on disk (R-09.1b.1), so this table
cannot silently fall behind the tree. Test counts are deliberately absent: they
go stale on every commit that adds a test, and a stale count in a specification
is worse than no count, because it reads as a claim.

## 5. Invariants

* I-09.1 The suite runs with no hypervisor, no network and no guest.
* I-09.2 No test requires a real credential.
* I-09.3 A missing optional tool is a visible skip, never a silent pass.
* I-09.4 A missing required tool is a named failure before any test runs.
* I-09.5 Every shipped defect has a named regression test.
* I-09.6 Uncovered requirements are named in §6, not left implied.
* I-09.7 Every test file present in the tree is named by the entry point, so a
  test that is written but never invoked cannot pass unnoticed.
* I-09.8 A run's reported result is identical whether or not timing is recorded.
* I-09.9 A test that asserts something about the tree first asserts that it
  found what it was looking for.
* I-09.10 A run's outcome is reported even when a suite could not be measured or
  could not run.

## 6. Acceptance

| ID | Criterion |
|---|---|
| A-09.1 | `tests/run.sh` with no arguments runs the static and unit layers and exits zero. |
| A-09.2 | `tests/run.sh --fast` runs the static layer only, and names the mode it ran. |
| A-09.3 | `tests/run.sh tests/unit/gpu-detect.bats` runs that file alone and reports one suite. |
| A-09.4 | A run in which one assertion fails prints that suite's full TAP output, including the assertion that failed, and exits non-zero. |
| A-09.5 | With a required tool absent, the run stops before any test executes and names the tool. |
| A-09.6 | With an optional tool absent, its checks report a skip and the run still passes. |
| A-09.7 | The run ends with a `key=value` result block whose keys are stable, and whose counts match the suites that ran. |
| A-09.8 | `bash tests/run-wsl.sh --setup` installs `bats` and `shellcheck` into the user's home and needs no `sudo`. |
| A-09.9 | The wrapper exits with the suite's status: non-zero when a test fails. |
| A-09.10 | The wrapper reports the pass, fail and skip counts, and the location of the timing records. |
| A-09.11 | Every run leaves one record line per test, and `tests/timing.sh report` prints totals, per-suite harness share, and the slowest tests. |
| A-09.12 | A test that finishes inside its body much faster than its suite's wall time is reported with the difference attributed to harness time, not to the test. |
| A-09.13 | A test that grows substantially between two consecutive runs is named in the report; a test whose change is only jitter is not. |
| A-09.14 | `tests/.timing/` is not tracked by version control. |
| A-09.15 | Every `.bats` file in the tree is named in the entry point's suite list. |
| A-09.16 | The four harness shell scripts pass `shellcheck`. |
| A-09.17 | A suite containing skipped tests reports them as skipped rather than passed, and its pass, fail and skip counts sum to its test count. |
| A-09.18 | The reported test count equals the number of rows the timing record holds for that run. |
| A-09.19 | A suite's reported in-test time is at least the sum of the times its own tests report, including its skipped ones. |
| A-09.20 | A test file present in the tree but absent from the suite list, or a suite label used twice, fails the suite rather than passing. |
| A-09.21 | A new file under `tests/static/` that is not reachable from `--fast` fails the suite. |
| A-09.22 | A test file the framework cannot parse is reported with the framework's own error text, counted as a failed suite, and the run still prints its result block. |
| A-09.23 | A suite that exits non-zero without recording a failed test is counted as a failed suite, and the run exits non-zero. |

## 7. Known gaps

| Gap | Consequence |
|---|---|
| No test boots a guest or runs a first-boot script end to end | A first-boot script that passes every static check can still fail at runtime (R-07.7 acceptance covers this on hardware) |
| Firewall and name-service rules are syntax-checked, not exercised | A rule that parses but does not match real traffic passes. Egress was wrong once already (D-09 "desktop unrestricted") and only a hardware run would have caught it |
| No test asserts a guest's final hostname after a clone beyond the source of the mechanism | The mechanism is asserted; the guest's response is not |
| No test covers the inference container's runtime behaviour | Spec 03 §R-03.5 is verified on hardware only |
| `nvidia` driver and CUDA versions are not pinned to a digest | A first boot can install a different combination on a new release; the log records what it got, but nothing constrains it |
| Timing records are not committed, so regressions are only visible per machine | A slowdown introduced on one workstation is invisible to everyone else. Comparing records across machines would need a shared store and a normalised baseline, because the harness share depends on the host |
| Harness overhead is measured, not reduced | The per-test cost is the framework's, and the report makes its share visible. Cutting it further means running fewer, larger suites, which trades away the ability to run one area in isolation |
| No test asserts that specs' acceptance tables match the test suite | A requirement can be added to a spec with no test, and this spec will not notice |

## 8. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Sourcing and pinning rules the static layer enforces |
| Spec 01 | The build and provisioning behaviour most heavily tested |
| Spec 05 | The credential invariants the suite protects |
| Spec 06 | Placeholder and key-injection invariants |
| Spec 07 | The credential matrix, dev range and pin consistency |
| Spec 08 | Credential paths and output ownership |
