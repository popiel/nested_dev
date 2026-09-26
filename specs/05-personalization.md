# Spec 05 — Personalization (non-root user identity)

Status: Draft (new; consolidates user identity scattered across Specs 02–04)
Pinned versions: Ubuntu Server/Desktop **26.04 LTS**, Proxmox VE **9.2**

## 1. Purpose and scope

Define the **single canonical source** for non-root user identity across all
VMs and containers in the nested_dev fleet. Every spec and build script
references this spec (and the shared config file it defines) instead of
hardcoding user values.

In scope: username, full name, email, UID/GID, home directory, SSH key
placement, git identity, login password hash. Out of scope: per-VM
hostnames, network config, package choices.

## 2. User identity

| Attribute | Value |
|---|---|
| Username | `popiel` |
| Full name | `T. Alexander Popiel` |
| Email | `tapopiel@gmail.com` |
| UID | `1401` (set explicitly at install time; avoids collision with container default UIDs) |
| GID | `1401` |
| Home | `/home/popiel` |
| Shell | `/bin/bash` |
| Host privileges | Member of `sudo`; `keys/host_os_ed25519.pub` installed in `~/.ssh/authorized_keys` |
| SSH | Key-only in guests (`install-server: true`, `allow-pw: false`); password login also works for the host account |
| Docker group | Added at first boot where Docker is installed |
| Repo | `popiel/nested_dev` (GitHub `<user>/<repo>`) |
| Tag | `host_os_v0.1` (release tag for build manifests and first-boot refs) |

The same account exists on the **host** (PVE) and in **all three guests**. The
PVE web UI is *not* covered: a Linux `sudo` user is not a PVE realm user, and
granting UI access needs a separate `pve realm add <user>@pam` on the host.
That is deliberately out of scope here.

## 3. Canonical config file

`provision/personalization.sh` — sourced by all build scripts and
first-boot scripts. Contains shell variables for every value above.

```bash
# provision/personalization.sh — shared user identity variables
# Source this file in all build scripts and first-boot scripts.
# Canonical source: specs/05-personalization.md

PERSONALIZATION_USERNAME="popiel"
PERSONALIZATION_FULLNAME="T. Alexander Popiel"
PERSONALIZATION_EMAIL="tapopiel@gmail.com"
PERSONALIZATION_UID="1401"
PERSONALIZATION_GID="1401"
PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"

# Repository and release reference
# Set to a branch name, tag, or full commit SHA:
#   "main"              — track tip of main branch (latest changes)
#   "some-tag"          — pinned to a specific tag
#   "abc123def456..."   — pinned to an exact commit SHA (most reproducible)
PERSONALIZATION_REPO="popiel/nested_dev"
PERSONALIZATION_REF="main"
```

Scripts source it with:
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../provision/personalization.sh"  # adjust relative path
```

## 4. Per-VM user provisioning

All three guest VMs (Desktop §02, LLM §03, Dev §04) create the same
non-root account via cloud-init `identity:` block:

```yaml
identity:
  hostname: <vm-specific>
  username: __PERSONALIZATION_USERNAME__
  password: "CHANGE_ME_HASHED"
  realname: "__PERSONALIZATION_FULLNAME__"
```

The `user-data` YAML files carry the placeholder names; `frag/30` substitutes
the real values at guest-creation time. The autoinstall `identity:` block does
not support a `uid` field, so the UID/GID are set via `late-commands`:

```yaml
late-commands:
  - "curtin in-target --target=/target -- usermod -u 1401 __PERSONALIZATION_USERNAME__"
  - "curtin in-target --target=/target -- groupmod -g 1401 __PERSONALIZATION_USERNAME__"
  # Guest root has no password at all (§5.4)
  - "curtin in-target --target=/target -- passwd -l root"
```

Each guest first-boot script sources `provision/personalization.sh` and
uses the variables for `chown`, `usermod`, `loginctl`, `getent`, and
`git config` calls.

### 4.1 The host account

PVE's autoinstall schema cannot create a non-root user: `[global]` accepts
only `root-password` / `root-password-hashed` and `root-ssh-keys`, and there is
no `late-commands` section. The host account is therefore created by the
first-boot bootstrap (`provision/host/first-boot.sh`, embedded in the ISO via
`--on-first-boot`), which is the schema-supported replacement for the removed
`late-commands`.

`build-iso.sh` renders the identity and the hash into that bootstrap as
`__PERSONALIZATION_USERNAME__`, `__PERSONALIZATION_FULLNAME__`,
`__PERSONALIZATION_UID__`, `__PERSONALIZATION_GID__`,
`__PERSONALIZATION_HOME__`, `__ADMIN_PUBKEY__` and
`__PERSONALIZATION_PASSWORD_HASH__`, and the bootstrap then:

1. `groupadd -g ${PERSONALIZATION_GID}` / `useradd -u ${PERSONALIZATION_UID}
   -g ${PERSONALIZATION_GID} -d ${PERSONALIZATION_HOME} -s /bin/bash -c
   "${PERSONALIZATION_FULLNAME}" ${PERSONALIZATION_USERNAME}` — idempotent, and
   it refuses to proceed if the UID or GID already belongs to a different
   account rather than creating a second identity for one operator.
2. Applies the hash verbatim with `chpasswd -e` (an already-encrypted
   password, so no plaintext ever touches disk and the host gets the identical
   yescrypt string the guests receive).
3. `usermod -aG sudo`, then installs `keys/host_os_ed25519.pub` as
   `~/.ssh/authorized_keys` (600, `~/.ssh` 700, home `chown`ed to the account).

It runs **before** the provision tree is fetched, so the host still has an
operator account if the GitHub fetch fails.

## 5. Password hashes

Two credentials, two files, both gitignored and read only at build time:

| File | Credential | Used by |
|---|---|---|
| `keys/personalization-password-hash` | Login password for `${PERSONALIZATION_USERNAME}` | The host account (§4.1) and all three guests, via `CHANGE_ME_HASHED` |
| `keys/root-password-hash` | PVE `root` on the host | The answer file's `root-password-hashed`, and nowhere else |

They are deliberately separate files: while one file fed both, every leak of
the account's login password would have been a leak of the host's most
privileged credential too. `keys/root-password-hash` never enters the
first-boot bootstrap, and `frag/30` never sees it.

The `user-data` YAML files contain only the placeholder `CHANGE_ME_HASHED`;
the real hash is injected at build time.

### 5.1 Generating the hashes

```bash
# Login password for the personalization account (host + all guests)
mkpasswd -m yescrypt > keys/personalization-password-hash
# Separate break-glass password for PVE root on the host only
mkpasswd -m yescrypt > keys/root-password-hash
# Paste or type the password when prompted; the hash is written to the file.
chmod 600 keys/personalization-password-hash keys/root-password-hash
```

### 5.2 Runtime injection (host-mediated)

The host reads `keys/personalization-password-hash` at ISO build time and
embeds it in the first-boot bootstrap, which is carried by the installer media
(`source = "from-iso"`, never a URL). During the first boot the bootstrap
creates the host account from it (§4.1) and persists it to
`/root/.personalization-password-hash`. At guest VM creation time (Spec 06),
the host's `frag/30-create-guests.sh` reads that file and injects the hash into
fetched user-data templates:

```bash
PASS_HASH="$(cat /root/.personalization-password-hash)"
sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
    "${TEMPLATE_DIR}/user-data/user-data" > "${WORK_DIR}/user-data"
```

The root hash takes the other path: `build-iso.sh` substitutes it into
`answer-host.toml`'s `root-password-hashed`, and the installer writes it
directly to `/etc/shadow`. It is never persisted to a file the provisioner
can read.

### 5.3 Git hook

`.githooks/pre-commit` blocks commits where any `user-data/user-data`
file contains a real hash instead of `CHANGE_ME_HASHED`. Enable with:

```bash
git config core.hooksPath .githooks
```

`tests/static/invariants.bats` additionally asserts that neither hash file is
git-tracked, that no committed host template contains a hash, and that the
renamed `keys/personalization-password-hash` path is the only one referenced.

### 5.4 Root has no password, anywhere but the host

| Account | Password |
|---|---|
| Host `root` | `keys/root-password-hash` (via the answer file) |
| Host `${PERSONALIZATION_USERNAME}` | `keys/personalization-password-hash` |
| Guest `${PERSONALIZATION_USERNAME}` | same hash, injected at guest creation |
| Guest `root` | **none** — each seed runs `passwd -l root` |

subiquity already leaves guest `root` locked, but the seeds say so explicitly
rather than depending on that default, so a later change to the `identity:`
block cannot quietly introduce a guest root credential.

### 5.5 File layout

| File | Purpose | Committed? |
|---|---|---|
| `keys/personalization-password-hash` | yescrypt hash of the login password (host account + all guests) | No (gitignored) |
| `keys/root-password-hash` | yescrypt hash of the PVE `root` password (host only) | No (gitignored) |
| `/root/.personalization-password-hash` | On-host copy for `frag/30`, 600 | No (runtime) |
| `keys/host_os_ed25519.pub` | Operator public key from the build machine, trusted on the host and on every guest | Yes (public key only) |
| `*/user-data/user-data` | Contains `CHANGE_ME_HASHED` placeholder | Yes |
| `.githooks/pre-commit` | Blocks real hashes in user-data | Yes |

### 5.5 Install-time generated credentials

Two keypairs are generated on the host at first boot rather than committed,
because the private halves must never exist in the repo (Spec 07):

| Keypair | Private half | Public half trusted by |
|---|---|---|
| vmctl control | desktop `~/.ssh/pvehost_vmctl` | host `vmctl` account (`ForceCommand`-restricted) |
| guest identity | desktop `~/.ssh/nested-dev-id` | host root (pinned to the desktop address) + all guests |

`keys/host_os_ed25519.pub` is the exception: it is a public key, so it is
committed, and `first-boot.sh` copies it out of the fetched repo tarball into
`/root/provision/keys/` because `keys/` is not part of the provision tree.
`frag/30` then injects it into every guest seed as
`ssh_authorized_keys`, so the operator key works on the host and all guests.

## 6. Git identity (dev VM only)

Set at first boot in the Dev VM (Spec 04 §5 step 3):

```bash
git config --global user.name "${PERSONALIZATION_FULLNAME}"
git config --global user.email "${PERSONALIZATION_EMAIL}"
```

Only the Dev VM configures git; Desktop and LLM VMs do not.

## 7. Fork and tagging protocol

### 7.1 Forking

Each user forks the repo and customizes `provision/personalization.sh`
with their own identity. No other files need editing for personalization —
the build scripts source the shared config, and `build-iso.sh` renders it into
the host first-boot bootstrap at build time, because the host account has to
exist before the provision tree (which carries the config) can be fetched.

### 7.2 Tag format

Tags mark a known-good set of ISOs. Format: `host_os_v<major>.<minor>`

| Tag | Meaning |
|---|---|
| `host_os_v0.1` | First release — initial host + guest images |
| `host_os_v0.2` | Incremental update (e.g. new package, config change) |
| `host_os_v1.0` | Stable baseline for production use |

Tags are **immutable** — once an ISO is built from a tagged commit, that
commit is never modified. A new tag is created for any change that affects
the built images.

### 7.3 Tagging workflow

1. Make changes, commit, verify builds.
2. Update `PERSONALIZATION_REF` in `provision/personalization.sh`:
   ```bash
   PERSONALIZATION_REF="some-tag"   # or a branch name, or a full SHA
   ```
3. Commit and push.
4. If using a tag, create and push it:
   ```bash
   git tag some-tag
   git push origin some-tag
   ```
5. Build the host ISO — the manifest records the REF and resolved SHA.

### 7.4 What the REF controls

- Host `build-iso.sh` sets `REF="${PERSONALIZATION_REF}"` — resolved to
  a commit SHA via `git ls-remote`, recorded in the host ISO's `MANIFEST`.
- Raw GitHub URLs use the REF directly (branch names and tags resolve
  automatically); the SHA is for logging and reproducibility.
- First-boot script headers reference the REF as the fetch point.

## 8. Cross-references

| Spec | How it uses personalization |
|---|---|
| Spec 01 (Host) | Host account creation in the first-boot bootstrap (§4.1), root hash in the answer file |
| Spec 02 (Desktop) | cloud-init identity, first-boot `chown`/`loginctl`, SSH examples |
| Spec 03 (LLM) | cloud-init identity, first-boot `chown`, serial autologin |
| Spec 04 (Dev) | cloud-init identity, first-boot `chown`/`usermod`/`git config`, wrapper paths |

All three guest specs' `Decisions` tables include an `Account` row that says
"`popiel` (§05)" instead of repeating the full identity.

## 9. Acceptance

* `provision/personalization.sh` defines all variables; no hardcoded
  `popiel` / `T. Alexander Popiel` / `tapopiel@gmail.com` in any build
  script or first-boot script.
* Every VM's cloud-init `identity.username` matches
  `${PERSONALIZATION_USERNAME}`.
* `grep -r 'popiel\|T\. Alexander\|tapopiel' provision/ desktop/ llm/`
  returns only the shared config file and references to it.
* `keys/personalization-password-hash` and `keys/root-password-hash` both
  exist, are gitignored, and neither is git-tracked; `user-data` files contain
  only `CHANGE_ME_HASHED`.
* The two hashes are never interchangeable: the answer file carries only
  `__ROOT_PASSWORD_HASH__`, the first-boot bootstrap only
  `__PERSONALIZATION_PASSWORD_HASH__`.
* On the installed host: `id ${PERSONALIZATION_USERNAME}` shows uid 1401 and a
  `sudo` group; `getent shadow` shows its password hash equal to
  `keys/personalization-password-hash`; `~/.ssh/authorized_keys` holds
  `keys/host_os_ed25519.pub`; `getent shadow root` shows the *other* hash.
* In every guest, root is locked (`passwd -S root` reports `L`) and the
  personalization account is the only login.
* `keys/host_os_ed25519.pub` is git-tracked.
* `.githooks/pre-commit` is present and executable.
* `PERSONALIZATION_REPO` and `PERSONALIZATION_REF` are defined in
  `provision/personalization.sh`; no hardcoded refs in any build script.
* `PERSONALIZATION_REF` matches the intended branch, tag, or SHA.
