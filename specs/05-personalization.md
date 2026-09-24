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
| UID | `1401` (explicitly set via `usermod` in `late-commands`; avoids collision with container default UIDs) |
| GID | `1401` (set via `groupmod` in `late-commands`) |
| Home | `/home/popiel` |
| Shell | `/bin/bash` |
| SSH | Key-only; `install-server: true`, `allow-pw: false` in cloud-init |
| Docker group | Added at first boot where Docker is installed |
| Repo | `popiel/nested_dev` (GitHub `<user>/<repo>`) |
| Tag | `host_os_v0.1` (release tag for build manifests and first-boot refs) |

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

# Repository and release tag
PERSONALIZATION_REPO="popiel/nested_dev"
PERSONALIZATION_TAG="host_os_v0.1"
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
  username: ${PERSONALIZATION_USERNAME}
  password: "CHANGE_ME_HASHED"
  realname: "${PERSONALIZATION_FULLNAME}"
```

The `user-data` YAML files for each VM use the shell variables above in
`late-commands` via `sed` substitution or direct reference to the shared
config. The autoinstall `identity:` block does not support a `uid` field,
so the UID/GID are set via `late-commands`:

```yaml
late-commands:
  - "curtin in-target --target=/target -- usermod -u ${PERSONALIZATION_UID} ${PERSONALIZATION_USERNAME}"
  - "curtin in-target --target=/target -- groupmod -g ${PERSONALIZATION_GID} ${PERSONALIZATION_USERNAME}"
```

Each first-boot script sources `provision/personalization.sh` and
uses the variables for `chown`, `usermod`, `loginctl`, `getent`, and
`git config` calls.

## 5. Password hash

The login password hash is stored in `keys/password-hash` (gitignored,
never committed). The `user-data` YAML files contain only the placeholder
`CHANGE_ME_HASHED`; the real hash is injected at build time.

### 5.1 Generating the hash

```bash
# Generate a yescrypt hash (Ubuntu 24.04+ default) — run once, manually
mkpasswd -m yescrypt > keys/password-hash
# Paste or type the password when prompted; the hash is written to the file.
chmod 600 keys/password-hash
```

### 5.2 Runtime injection (host-mediated)

The host reads `keys/password-hash` at ISO build time and embeds it in
the host ISO. During PVE install, the password hash is persisted to
`/root/.password-hash`. At guest VM creation time (Spec 06), the host's
`frag/30-create-guests.sh` reads this file and injects the hash into
fetched user-data templates:

```bash
PASS_HASH="$(cat /root/.password-hash)"
sed -e "s|CHANGE_ME_HASHED|${PASS_HASH}|g" \
    "${TEMPLATE_DIR}/user-data/user-data" > "${WORK_DIR}/user-data"
```

### 5.3 Git hook

`.githooks/pre-commit` blocks commits where any `user-data/user-data`
file contains a real hash instead of `CHANGE_ME_HASHED`. Enable with:

```bash
git config core.hooksPath .githooks
```

### 5.4 File layout

| File | Purpose | Committed? |
|---|---|---|
| `keys/password-hash` | yescrypt hash of login password | No (gitignored) |
| `*/user-data/user-data` | Contains `CHANGE_ME_HASHED` placeholder | Yes |
| `.githooks/pre-commit` | Blocks real hashes in user-data | Yes |

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
all build scripts and first-boot scripts source the shared config.

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
2. Update `PERSONALIZATION_TAG` in `provision/personalization.sh`:
   ```bash
   PERSONALIZATION_TAG="host_os_v0.2"
   ```
3. Commit the tag change.
4. Create the git tag:
   ```bash
   git tag host_os_v0.2
   git push origin host_os_v0.2
   ```
5. Build all ISOs — the manifest records the tag.

### 7.4 What the tag controls

- Host `build-iso.sh` sets `REF="${PERSONALIZATION_TAG}"` — recorded in
  the host ISO's `MANIFEST` entry.
- `MANIFEST` entries include the repo name and tag for traceability.
- First-boot script headers reference the tag as the fetch point.

## 8. Cross-references

| Spec | How it uses personalization |
|---|---|
| Spec 02 (Desktop) | cloud-init identity, first-boot `chown`/`loginctl`, SSH examples |
| Spec 03 (LLM) | cloud-init identity, first-boot `chown`, serial autologin |
| Spec 04 (Dev) | cloud-init identity, first-boot `chown`/`usermod`/`git config`, wrapper paths |

All three specs' `Decisions` tables include an `Account` row that says
"`popiel` (§05)" instead of repeating the full identity.

## 9. Acceptance

* `provision/personalization.sh` defines all variables; no hardcoded
  `popiel` / `T. Alexander Popiel` / `tapopiel@gmail.com` in any build
  script or first-boot script.
* Every VM's cloud-init `identity.username` matches
  `${PERSONALIZATION_USERNAME}`.
* `grep -r 'popiel\|T\. Alexander\|tapopiel' provision/ desktop/ llm/`
  returns only the shared config file and references to it.
* `keys/password-hash` exists and is gitignored; `user-data` files contain
  only `CHANGE_ME_HASHED`.
* `.githooks/pre-commit` is present and executable.
* `PERSONALIZATION_REPO` and `PERSONALIZATION_TAG` are defined in
  `provision/personalization.sh`; no hardcoded `host_os_v0.1` in any
  build script.
* `PERSONALIZATION_TAG` matches the current git tag.
