# Spec 05 — Personalization (non-root user identity)

Status: Draft
Applies to: Host (PVE) and every guest VM in the fleet
Pinned versions: Ubuntu Server/Desktop **26.04 LTS**, Proxmox VE **9.2**
Implementation: `provision/personalization.sh`, `provision/host/first-boot.sh`,
`provision/host/frag/30-create-guests.sh`

## 1. Scope

Defines the single source of non-root user identity for the host and all
guests. No other spec or script hardcodes a username, full name, email, UID or
GID.

In scope: username, full name, email, UID/GID, home directory, shell, SSH key
placement, git identity, login password hash, release reference. Out of scope:
per-VM hostnames, network configuration, package selection.

## 2. Requirements

### R-05.1 One canonical identity source

`provision/personalization.sh` defines every identity and repository value as
a shell variable. It is the only place in the repository where an identity
value appears literally.

* **R-05.1.1** No build script, first-boot script, seed template, Dockerfile
  or test file may contain a literal username, full name, email, UID or GID
  outside `provision/personalization.sh`.
* **R-05.1.2** The required variables are `PERSONALIZATION_USERNAME`,
  `PERSONALIZATION_FULLNAME`, `PERSONALIZATION_EMAIL`, `PERSONALIZATION_UID`,
  `PERSONALIZATION_GID`, `PERSONALIZATION_HOME`, `PERSONALIZATION_REPO`,
  `PERSONALIZATION_REF` and `PERSONALIZATION_TARGET_DISKS`.
* **R-05.1.3** `PERSONALIZATION_HOME` is derived from `PERSONALIZATION_USERNAME`
  rather than restated.
* **R-05.1.4** A script that consumes an unset required variable **fails with a
  message naming the variable** and pointing at `personalization.sh`. It does
  not substitute a default. An unset `PERSONALIZATION_UID` that silently
  defaulted would give guests an account whose identity no longer matches the
  host's, and the mismatch surfaces only as a bind-mount permission error much
  later.
* **R-05.1.5** `PERSONALIZATION_TARGET_DISKS` is build-host-specific and is
  permitted to be empty. Every other variable is required.

### R-05.2 The same account on host and in all guests

* **R-05.2.1** The host and all three guest families (desktop, LLM, dev) have
  an account with the configured username, full name, UID, GID, home and
  `/bin/bash` shell.
* **R-05.2.2** The account is a member of `sudo` on the host.
* **R-05.2.3** The UID is set explicitly rather than inherited from the
  distro default, so that a container's default UID cannot collide with it.
* **R-05.2.4** Guests accept the operator's public key
  (`keys/host_os_ed25519.pub`) as a login credential and disable password
  authentication for SSH. The account's password hash is still set, because
  console and RDP access need it; it is simply not accepted over SSH.
* **R-05.2.5** The account is added to the `docker` group wherever Docker is
  installed.

### R-05.3 The host account is created after installation, not by the answer file

* **R-05.3.1** The host account is created by the first-boot bootstrap
  (`provision/host/first-boot.sh`), not by the installer answer file. The PVE
  answer schema accepts no non-root user, so this is the only mechanism
  available (Spec 01 §4).
* **R-05.3.2** Account creation is **idempotent**: re-running it is a no-op.
* **R-05.3.3** If the configured UID or GID already belongs to a *different*
  account, creation **aborts**. Creating a second identity for one operator
  leaves two accounts that both appear to work and neither of which owns the
  files the other created.
* **R-05.3.4** The account's home directory is owned by the account, and
  `~/.ssh` is mode 700 with `authorized_keys` mode 600.
* **R-05.3.5** The GECOS field carries the configured full name, not the
  username, so `ls` and mail headers show the person's name.
* **R-05.3.6** Account creation completes **before** the provision tree is
  fetched from the network. A failed or unreachable fetch must still leave a
  usable operator login, because the alternative is a host with no account but
  `root` that the operator does not have the password for.
* **R-05.3.7** The bootstrap never creates, re-credentials or otherwise touches
  the `root` account. See R-05.4.

### R-05.4 Two credentials, two files, disjoint destinations

Two distinct credentials exist and must never be conflated.

| Credential | Reads from | Reaches | Never reaches |
|---|---|---|---|
| Host `root` | `keys/root-password-hash` | The host's `/etc/shadow`, written by the installer | Any file the provisioner can read; any guest |
| `${PERSONALIZATION_USERNAME}` | `keys/personalization-password-hash` | The host account, and the account of every guest | The host's `root` account |

* **R-05.4.1** Both files are gitignored and are read only at build time on the
  build workstation. Neither is git-tracked.
* **R-05.4.2** The two hashes are separate files, not one file read twice. A
  single file makes the login password and the host's most privileged
  credential the same secret, so any leak of the *login* password — the one
  shared with three VMs and reachable from a laptop over RDP — is also a leak
  of host root. A file that leaked is a file nobody can scope.
* **R-05.4.3** The answer file carries only the root hash. The first-boot
  bootstrap carries only the login hash. A build that cannot find one hash
  file **fails naming which file** — "hash not found" alone does not tell the
  operator which of the two secrets to generate.
* **R-05.4.4** The login hash travels on the installer media inside the
  first-boot bootstrap, never as a URL and never through the installer
  media's own fetch. The media is the same trust domain as the answer file's
  root hash; a URL would put the login password in a proxy log, a CDN cache or
  a shell history.
* **R-05.4.5** The rendered bootstrap is as sensitive as the hash file it
  contains and is treated the same way: not committed, not distributed
  separately from the ISO.

### R-05.5 Guest `root` has no password

* **R-05.5.1** `root` is locked in every guest, stated explicitly by every
  seed rather than relying on the installer's default. A default that is
  correct today stops being correct the moment someone edits the `identity:`
  block, and nothing in the seed would object.
* **R-05.5.2** No seed does anything to guest `root` other than lock it — no
  `chpasswd`, no `usermod -p`, no unlock-then-relock.
* **R-05.5.3** The account from R-05.2 is the only unlocked login in a guest.

### R-05.6 Identity is injected, never committed

* **R-05.6.1** Seed templates and the bootstrap carry placeholder tokens, never
  a real value. A committed hash is published to the repository and shipped in
  every ISO ever built from it.
* **R-05.6.2** The renderer fails the build if a placeholder token survives
  substitution. A surviving token ships a guest with no login hash, no
  operator key, or a UID that is literally `__PERSONALIZATION_UID__`.
* **R-05.6.3** A pre-commit hook and a static test both reject a real password
  hash appearing in any committed template.

### R-05.7 Git identity is configured only where it is used

* **R-05.7.1** The dev guest sets the configured `user.name` and `user.email`
  as the account's global git config. The desktop and LLM guests do not.

### R-05.8 The release reference is declared once

* **R-05.8.1** `PERSONALIZATION_REPO` and `PERSONALIZATION_REF` are defined in
  `provision/personalization.sh`. No script carries a literal repository or
  ref.
* **R-05.8.2** `PERSONALIZATION_REF` may be a branch name, a tag or a full
  40-character commit SHA. Branch names and tags resolve automatically in
  fetch URLs.
* **R-05.8.3** Resolution of a ref to a commit SHA is **defined once** in
  `provision/personalization.sh`. Two definitions of the same lookup can
  disagree, and the two consumers would then fetch different trees while
  reporting the same ref in their manifests.
* **R-05.8.4** Resolving a ref **never fails**: it returns successfully with an
  empty string when the ref is unresolvable, `git` is absent, or the network
  is down. Callers run under `set -euo pipefail`, where a non-zero return
  aborts a provisioning run in progress. Whether an unresolved ref is fatal is
  the caller's decision, not the resolver's.
* **R-05.8.5** A full 40-hex input is passed through without a `git` call.
* **R-05.8.6** When a ref names both a branch and a tag, the branch wins.
* **R-05.8.7** The resolved commit SHA is recorded in the build manifest, so a
  build is traceable to a specific tree even when the ref was a moving branch.
* **R-05.8.8** A ref is used unchanged for the host install media, the
  provisioner, and every guest's first-boot fetch. Guests must not fetch a
  different tree than the host that created them.

### R-05.9 Public keys are the exception to the secrecy rules

* **R-05.9.1** `keys/host_os_ed25519.pub` is committed. It is a public key.
* **R-05.9.2** Guests and the host are provisioned from that file, not from
  the host's `authorized_keys`. Reading the host's file would silently
  propagate a key an operator added by hand to every VM in the fleet.
* **R-05.9.3** Keypairs whose private halves must never exist in the
  repository are generated on the host at install time (Spec 07).

### R-05.10 Forking

* **R-05.10.1** A fork owner personalizes the deployment by editing
  `provision/personalization.sh` and nothing else.
* **R-05.10.2** Because R-05.1 forbids literals elsewhere, that single edit
  changes the identity of the host account and all guests, including UID, GID
  and the git identity.

## 3. Invariants

* I-05.1 `provision/personalization.sh` is the only file containing a literal
  identity value.
* I-05.2 The root hash and the login hash have disjoint destinations. Nothing
  the provisioner runs can read the root hash.
* I-05.3 No committed file contains a real password hash.
* I-05.4 Neither hash file is git-tracked.
* I-05.5 `resolve_ref_to_sha` is defined in exactly one file.
* I-05.6 The host account exists even if the provision-tree fetch fails.

## 4. Acceptance

| # | Check |
|---|---|
| A-05.1 | `provision/personalization.sh` defines every variable in R-05.1.2; `PERSONALIZATION_HOME` is derived, not restated. |
| A-05.2 | A search for the configured username, full name and email across `provision/`, `desktop/`, `llm/`, `dev/` returns only `provision/personalization.sh` and references to it. |
| A-05.3 | Every seed template carries `__PERSONALIZATION_USERNAME__`, `__PERSONALIZATION_FULLNAME__`, `__PERSONALIZATION_UID__` and `__PERSONALIZATION_GID__`; none carries a literal identity value. |
| A-05.4 | `PERSONALIZATION_UID` unset makes each consumer fail naming the variable. |
| A-05.5 | On the installed host: `id ${PERSONALIZATION_USERNAME}` shows the configured UID and a `sudo` group; `getent passwd` shows the configured GID, home and `/bin/bash`; GECOS is the full name. |
| A-05.6 | The host account's `~/.ssh` is 700, `authorized_keys` is 600, home is owned by the account, and `authorized_keys` contains the operator public key. |
| A-05.7 | The host account's shadow entry equals `keys/personalization-password-hash`; host `root`'s shadow entry is a *different* hash and equals `keys/root-password-hash`. |
| A-05.8 | The rendered answer file contains the root hash and no trace of the login hash; the rendered bootstrap contains the login hash and no token or value for the root hash. |
| A-05.9 | Removing either hash file produces a build error naming that specific file. |
| A-05.10 | Re-running the host account block is a no-op; a UID already owned by another account aborts rather than creating a second identity. |
| A-05.11 | The account is created before the provision fetch: a fetch pointed at an unreachable host still leaves a working operator login. |
| A-05.12 | In every guest, `passwd -S root` reports `L`, and the account from R-05.2 is the only unlocked login. No seed contains any other root-credential operation. |
| A-05.13 | The rendered answer file and the rendered bootstrap contain no surviving `__PLACEHOLDER__` token. |
| A-05.14 | Both hash files exist, are gitignored and are not git-tracked; no committed template matches a real-hash pattern. |
| A-05.15 | `resolve_ref_to_sha` is defined in exactly one script, and behaves per R-05.8.4–R-05.8.6 for branch, tag, 40-hex, unresolvable, absent `git`, and `git` exiting non-zero. |
| A-05.16 | `keys/host_os_ed25519.pub` is git-tracked. |
| A-05.17 | A pre-commit hook and a static test both reject a real hash in any seed template. |

## 5. Cross-references

| Spec | Uses personalization for |
|---|---|
| Spec 01 | Host account creation in the first-boot bootstrap; root hash in the answer file |
| Spec 02 | Desktop seed identity, first-boot `chown`/`loginctl`, SSH examples |
| Spec 03 | LLM seed identity, first-boot `chown` |
| Spec 04 | Dev seed identity, first-boot `chown`/`usermod`/`git config`, wrapper paths |
| Spec 06 | Host-mediated injection of the login hash and keys into guest seeds |
| Spec 07 | Guest-identity and `vmctl` keypair generation; host trust pin |
| Spec 08 | `nested keys-status` reporting on both hashes |

## 6. Files

| File | Purpose | Committed |
|---|---|---|
| `provision/personalization.sh` | Identity and ref variables; `resolve_ref_to_sha` | Yes |
| `keys/host_os_ed25519.pub` | Operator public key, trusted on host and all guests | Yes |
| `keys/personalization-password-hash` | yescrypt hash of the login password (host account + all guests) | No |
| `keys/root-password-hash` | yescrypt hash of the PVE `root` password (host only) | No |
| `/root/.personalization-password-hash` | On-host copy of the login hash for the seed renderer, mode 600 | Runtime only |
| `.githooks/pre-commit` | Rejects a real hash in a seed template | Yes |

### Non-normative note — why the two hashes are separate files

A single file serving both credentials makes the login password and host
`root` the same secret. That password is the one typed into three VMs and
accepted over RDP from a laptop on the LAN, so the blast radius of its
exposure is already wide. Sharing a file with host root means that wide blast
radius terminates in the host's most privileged account, and no scoping of the
leak is possible after the fact.
