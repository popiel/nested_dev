# Spec 05 — Personalization (non-root user identity)

Status: Draft (new; consolidates user identity scattered across Specs 02–04)
Pinned versions: Ubuntu Server/Desktop **26.04 LTS**, Proxmox VE **9.2**

## 1. Purpose and scope

Define the **single canonical source** for non-root user identity across all
VMs and containers in the nested_dev fleet. Every spec and build script
references this spec (and the shared config file it defines) instead of
hardcoding user values.

In scope: username, full name, email, UID/GID, home directory, SSH key
placement, git identity. Out of scope: per-VM hostnames, network config,
package choices.

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

## 5. Git identity (dev VM only)

Set at first boot in the Dev VM (Spec 04 §5 step 3):

```bash
git config --global user.name "${PERSONALIZATION_FULLNAME}"
git config --global user.email "${PERSONALIZATION_EMAIL}"
```

Only the Dev VM configures git; Desktop and LLM VMs do not.

## 6. Cross-references

| Spec | How it uses personalization |
|---|---|
| Spec 02 (Desktop) | cloud-init identity, first-boot `chown`/`loginctl`, SSH examples |
| Spec 03 (LLM) | cloud-init identity, first-boot `chown`, serial autologin |
| Spec 04 (Dev) | cloud-init identity, first-boot `chown`/`usermod`/`git config`, wrapper paths |

All three specs' `Decisions` tables include an `Account` row that says
"`popiel` (§05)" instead of repeating the full identity.

## 7. Acceptance

* `provision/personalization.sh` defines all variables; no hardcoded
  `popiel` / `T. Alexander Popiel` / `tapopiel@gmail.com` in any build
  script or first-boot script.
* Every VM's cloud-init `identity.username` matches
  `${PERSONALIZATION_USERNAME}`.
* `grep -r 'popiel\|T\. Alexander\|tapopiel' provision/ desktop/ llm/`
  returns only the shared config file and references to it.
