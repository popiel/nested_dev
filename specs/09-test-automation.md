# Spec 09 — Test automation

Status: Draft
Applies to: everything in this repository
Implementation: `tests/run.sh`, `tests/static/`, `tests/unit/`, `tests/lib/`,
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
| Layers | Static (lint, config, invariants) and unit (functions and files) |
| Style | Assertions read the repository's own files; a pure function is invoked and checked |
| Speed | No test may require a hypervisor, a network, or a real guest |
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

## 4. Coverage map

| Spec | Test file | Covers |
|---|---|---|
| 00 | `invariants.bats` | Sizing baselines, guest egress policy and its firewall rules, dev range containment |
| 01 | `build-iso.bats` | Disk validation, rendering, escaping, manifest, assistant failure detection, MSYS path handling |
| 01 | `invariants.bats` | Answer-file shape, bootstrap placeholders |
| 01 | `first-boot-user.bats` | Account creation ordering and idempotency, UID/GID shadowing, `root` handling |
| 01 | `frag10-iommu.bats` | Vendor detection, IOMMU flag mapping, audio companions, separability, virtio exclusion |
| 01 | `frag25-vmctl.bats` | Control account, keypair generation, host trust pin, pin/lease agreement |
| 02/03/04 | `configs.bats` | Seed YAML validity |
| 02/03/04 | `invariants.bats` | Placeholder inventory, desktop private-key exclusivity |
| 05 | `personalization.bats` | Variable definition, derived home, single definition of the shared resolver |
| 05 | `resolve-ref.bats` | Branch, tag, SHA pass-through, unresolvable, absent git, `set -e` safety |
| 05 | `first-boot-user.bats` | Two-hash split, no hash in the bootstrap, locked `root` in every seed |
| 06 | `frag25-vmctl.bats` | Placeholder survival detection, key injection, staged-key shredding and ordering |
| 06 | `invariants.bats` | Placeholder inventory completeness |
| 07 | `frag25-vmctl.bats` | Forced-command restriction, real shell, control-program installation, dev range, hostname settling, credential-path agreement, error text |
| 08 | `first-boot-user.bats` | Credential paths used by the build and by the operator-facing check |
| 09 | all | Source guards, lint coverage of extension-less scripts, dead-code detection |

**Totals: 187 tests** — 29 static, 158 unit, across 10 files.

## 5. Invariants

* I-09.1 The suite runs with no hypervisor, no network and no guest.
* I-09.2 No test requires a real credential.
* I-09.3 A missing optional tool is a visible skip, never a silent pass.
* I-09.4 A missing required tool is a named failure before any test runs.
* I-09.5 Every shipped defect has a named regression test.
* I-09.6 Uncovered requirements are named in §6, not left implied.

## 6. Known gaps

| Gap | Consequence |
|---|---|
| No test boots a guest or runs a first-boot script end to end | A first-boot script that passes every static check can still fail at runtime (R-07.7 acceptance covers this on hardware) |
| Firewall and name-service rules are syntax-checked, not exercised | A rule that parses but does not match real traffic passes. Egress was wrong once already (D-09 "desktop unrestricted") and only a hardware run would have caught it |
| No test asserts a guest's final hostname after a clone beyond the source of the mechanism | The mechanism is asserted; the guest's response is not |
| No test covers the inference container's runtime behaviour | Spec 03 §R-03.5 is verified on hardware only |
| `nvidia` driver and CUDA versions are not pinned to a digest | A first boot can install a different combination on a new release; the log records what it got, but nothing constrains it |
| The suite has no timing or performance budget | The `list` regression (D-09) was found by reading, not by a benchmark, and would pass every test even if reintroduced |
| No test asserts that specs' acceptance tables match the test suite | A requirement can be added to a spec with no test, and this spec will not notice |

## 7. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Sourcing and pinning rules the static layer enforces |
| Spec 01 | The build and provisioning behaviour most heavily tested |
| Spec 05 | The credential invariants the suite protects |
| Spec 06 | Placeholder and key-injection invariants |
| Spec 07 | The credential matrix, dev range and pin consistency |
| Spec 08 | Credential paths and output ownership |
