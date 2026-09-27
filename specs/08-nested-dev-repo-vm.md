# Spec 08 — The repository builds its own host image, from inside a dev VM

Status: Draft
Applies to: the builder dev VM (vm 103 and other clones that take this role)
Pinned versions: Ubuntu **26.04 LTS** build image, Proxmox VE **9.2** target
Implementation: `dev/tools/nested`, `dev/docker/Dockerfile.nested`,
`dev/tools/dev-refresh-images`, `provision/host/build-iso.sh`

## 1. Scope

The host install ISO is built from this repository, and the build needs tools
that do not belong on a desktop or in a dev VM's own filesystem. So the build
runs in a container on a dev VM: the dev VM supplies a checkout, a container
runtime and the two credential files; the container supplies the ISO-building
toolchain; the output comes back to the checkout.

In scope: the builder image, the wrapper interface, where credentials come
from, what the wrapper must not do, and output ownership. Out of scope: what
the ISO contains (Spec 01), dev VM lifecycle (Spec 07), the other tool
wrappers (Spec 04).

## 2. Decisions

| Aspect | Choice |
|---|---|
| Where the build runs | A container on a dev VM, never on the desktop, never on the host |
| Build image | Ubuntu 26.04, the same release as the guests, with the ISO-building toolchain and no desktop software |
| Repository source | A checkout the operator clones into the workspace; the wrapper does not clone it |
| Container identity | `root`, because the ISO builder needs it |
| Output | Written into the bind-mounted checkout, then handed back to the operator's account |
| Credentials | Read from the checkout's gitignored `keys/` directory; never copied into the image, never passed as build arguments |
| Image refresh | An explicit rebuild from scratch, on request |
| Per-project volume | Not used. Output lands on the dev VM's own disk |
| Network | The dev VM's egress policy applies: DNS, HTTP and HTTPS (Spec 04 §R-04.8.2) |

### 2.1 Why the build is not a script on the host

The ISO builder needs `xorriso`, archive tooling, and a container runtime of
its own. Installing that on the hypervisor means the build's dependencies sit
on the machine the build installs, and a build that goes wrong touches the
host. Keeping the toolchain in an image on a dev VM means the build is
reproducible from an image tag and the host carries no build dependencies at
all.

## 3. Requirements

### R-08.1 The builder image carries the build toolchain and nothing else

* **R-08.1.1** The image is based on the same Ubuntu release as the guests, so
  a build runs against the release it is building for.
* **R-08.1.2** It contains the tools the ISO build needs: download, ISO
  authoring, archive handling, WHOIS, version control, HTTP and GPG tooling,
  Python, and the container runtime client the builder uses to obtain the
  install assistant when it is not present natively.
* **R-08.1.3** It contains **no** desktop software, no GPU or CUDA stack, and no
  inference components. The build image is a build tool, and anything in it
  that is not needed to build is weight the operator pulls on every refresh.
* **R-08.1.4** Package installation leaves no apt lists behind, so a later
  layer does not carry a stale index.
* **R-08.1.5** The image runs a shell as its entry point and takes the build
  command as its argument, so the build is the only thing it does.
* **R-08.1.6** The image carries no credential, no key and no identity value.
  Every secret the build needs arrives through the bind-mounted checkout at
  run time, and is therefore absent from every layer and every cache entry.

### R-08.2 The wrapper is the interface, and it is thin

* **R-08.2.1** The wrapper exposes exactly four operations: build the host ISO,
  inspect the answer-file template, rebuild the builder image, and report
  whether the required credentials are present. Anything else is refused.
* **R-08.2.2** Each operation is described in the wrapper's own help. The
  operator should not have to read the wrapper to find out what it does.
* **R-08.2.3** An unrecognised operation prints the help and exits non-zero,
  rather than doing nothing and exiting zero. A wrapper that succeeds on a
  typo is a wrapper the operator stops trusting.
* **R-08.2.4** The wrapper requires a checkout at a known path inside the
  workspace, and says so — naming the command that creates it — when it is
  absent. It does not clone on the operator's behalf, because a build that
  silently fetches a different revision than the one the operator is reading
  produces an ISO nobody can account for.
* **R-08.2.5** The builder image is built on first use, not at first boot. A
  dev VM that has never run a build does not carry the builder image.

### R-08.3 The build runs against the checkout, and its output returns to it

* **R-08.3.1** The checkout is bind-mounted into the container at the same path
  it has on the dev VM, and the build runs with that path as its working
  directory. Identical paths inside and outside mean a path in a build log can
  be opened directly on the dev VM.
* **R-08.3.2** Output is written **into the checkout's own output directory**,
  which is bind-mounted, not into a container-local path. An ISO produced
  inside a container and not bind-mounted disappears when the container exits.
* **R-08.3.3** The container runs as `root`, so files it creates are
  root-owned on the dev VM. The wrapper hands them back to the operator's
  account immediately after the build, and a build that fails before the
  hand-back leaves files the operator cannot delete.
* **R-08.3.4** Both the output directory and the credential directory are
  handed back, because the build writes into both.
* **R-08.3.5** The build is non-interactive. A build that prompts produces a
  container that hangs until the operator attaches to it.

### R-08.4 Credentials come from the checkout and go nowhere else

* **R-08.4.1** The build reads the two password hashes and the operator's public
  key from the checkout's gitignored `keys/` directory.
* **R-08.4.2** The two hashes have distinct, non-interchangeable roles, and
  the build must keep them that way: the host's root credential goes only into
  the install answer file, and the operator login credential goes into the
  first-boot bootstrap and every guest seed. A build that swapped them
  produces a host whose root has the operator's password.
* **R-08.4.3** The credential directory is **gitignored except for its public
  parts.** A committed hash is a credential in a public repository's history,
  and removing it in a later commit does not remove it from the history.
* **R-08.4.4** The pre-commit hook and the static test both reject a committed
  hash or private key. Two independent gates, because the hook is skipped
  easily (`--no-verify`) and the test is not run at all.
* **R-08.4.5** Credential paths are stated in one place. A check that looks for
  a credential in a different directory than the build reads reports a working
  setup as broken, and tells the operator to create a second copy that no
  build ever reads.

### R-08.5 Answer-file inspection is honest about what it inspects

* **R-08.5.1** The wrapper's inspection operation states that the committed
  answer file is a **template** and that it is not validating it.
* **R-08.5.2** It says where validation actually happens: the build, which
  renders the template and validates the result with the version-matched
  install assistant.
* **R-08.5.3** It then prints the template. An operation that prints a template
  and reports success must not be named as if it verified the finished file —
  an operator who trusts the word "verify" will not read the output.

### R-08.6 Refreshing the builder image is deliberate

* **R-08.6.1** Refreshing rebuilds the builder image from scratch with the base
  image re-pulled and no cache, so a rebuild actually tests the current base
  rather than reusing cached layers.
* **R-08.6.2** The refresh reports the resulting image digest afterwards, so the
  operator can record which toolchain built a given ISO.
* **R-08.6.3** Refreshing is never automatic. A build that silently changed its
  toolchain would make two ISOs from the same commit differ.

### R-08.7 The build itself

* **R-08.7.1** The build validates its inputs before it downloads anything. In
  particular the target disk is validated **before** the multi-gigabyte install
  media step, so a malformed value fails in seconds rather than after the
  download it would have invalidated.
* **R-08.7.2** The build refuses to run when a required credential is absent,
  naming the file and how to produce it.
* **R-08.7.3** The build's exit status is meaningful, and a failure inside the
  assistant is not reported as success. The assistant can report a hard failure
  and still exit zero.
* **R-08.7.4** The build records what it produced and the reference it was built
  from, in a manifest written from values that were already computed and
  checked.
* **R-08.7.5** Build output is written outside version control.
* **R-08.7.6** The build does not care which shell invoked it, and does not
  depend on path-rewriting behaviour that differs between a Linux shell, a
  Windows Git Bash, and a Linux container. A build that works in one of the
  three and silently produces a different result in another is worse than a
  build that fails.

## 4. Invariants

* I-08.1 The build toolchain exists only inside the builder image.
* I-08.2 The builder image contains no credential.
* I-08.3 No credential is committed, and the two hashes never exchange roles.
* I-08.4 A build's output is on the dev VM's filesystem, owned by the operator.
* I-08.5 The builder image is rebuilt only on request.
* I-08.6 The build never fetches the repository itself.

## 5. Acceptance

| # | Check |
|---|---|
| A-08.1 | The builder image contains the ISO-authoring toolchain and contains no desktop, GPU or inference packages. |
| A-08.2 | The image contains no password hash, no private key, and no username, UID or email, at any layer. |
| A-08.3 | With no checkout in the workspace, the wrapper names the clone command and builds nothing. |
| A-08.4 | With a checkout present, the build produces an ISO in the checkout's output directory. |
| A-08.5 | The ISO's path is identical inside the container and on the dev VM, and a build log path can be opened directly on the dev VM. |
| A-08.6 | The built ISO is owned by the operator's account, including the credential directory's entries. |
| A-08.7 | A build that fails part-way still leaves output the operator can delete. |
| A-08.8 | With a credential file removed, the build stops and names the file and how to produce it. |
| A-08.9 | A malformed target-disk value fails in seconds, before any install media is downloaded. |
| A-08.10 | A build whose install assistant reports a hard failure exits non-zero. |
| A-08.11 | The manifest records the produced media's checksum and the reference the build used. |
| A-08.12 | The wrapper's inspection operation states that the file is an unvalidated template, and names where validation happens. |
| A-08.13 | An unrecognised wrapper operation prints help and exits non-zero. |
| A-08.14 | The builder image is absent from a dev VM that has never run a build. |
| A-08.15 | A refresh re-pulls the base image, discards the cache, and reports the resulting digest. |
| A-08.16 | Two builds of the same commit with no refresh produce the same builder image digest. |
| A-08.17 | Staging a hash in the credential directory and committing it is rejected by both the hook and the static test. |
| A-08.18 | No build output is tracked by version control. |
| A-08.19 | The build succeeds under a Linux shell, under Windows Git Bash, and inside the container, with the same result. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Sourcing policy, pinning, build ordering |
| Spec 01 | What the produced ISO does |
| Spec 04 | The dev VM this runs on; the container-only toolchain rule |
| Spec 05 | The two credential files and their non-interchangeable roles |
| Spec 07 | Which dev VM this is, and how it was created |
| Spec 09 | The credential and output tests above |

## 7. Known gaps

| Gap | Effect |
|---|---|
| No per-project data volume is attached to a dev VM | A checkout plus its ISO output share one 40 GB disk. Large checkouts will fill it (Spec 04 §R-04.9.2) |
| The builder image is not version-pinned to a digest | A refresh can change the toolchain. The digest is reported so the operator can record it, but nothing prevents the change (R-08.6.2) |
| The dev VM's 53/80/443-only egress covers the build's downloads, but the build cannot reach an internal mirror on any other port | A build that must fetch from an internal service on another port fails (Spec 04 §R-04.8.2) |
