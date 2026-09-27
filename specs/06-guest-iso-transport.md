# Spec 06 — Guest provisioning: how a guest gets its install and its identity

Status: Draft
Applies to: vm 100, vm 101, vm 102 and every dev VM clone
Pinned versions: Ubuntu **26.04 LTS**, Proxmox VE **9.2**
Implementation: `provision/host/frag/25-desktop-control.sh`,
`provision/host/frag/30-create-guests.sh`, `provision/host/build-iso.sh`

## 1. Scope

Defines how a guest obtains the material it needs to install itself and to
become a known member of the fleet: the official Ubuntu ISO, its NoCloud seed,
its login hash, and its SSH keys.

In scope: seed assembly, placeholder injection, guest creation, idempotency,
provenance of every input, and the trust model for the credentials involved.
Out of scope: what a guest does with the seed (Specs 02/03/04), host install
media (Spec 01), dev VM cloning after creation (Spec 07).

## 2. Requirements

### R-06.1 Guests install from official media with a host-assembled seed

* **R-06.1.1** Every guest installs unattended from the **official** Ubuntu
  ISO, downloaded by the host from the Ubuntu release server. No guest ISO is
  built or customised in this repository.
* **R-06.1.2** The host assembles a NoCloud seed per guest — the rendered
  user-data plus a meta-data marker — and attaches it as a cdrom alongside the
  official ISO.
* **R-06.1.3** The installer detects the seed automatically. No per-guest
  kernel arguments or serial console interaction are required to point the
  installer at it.
* **R-06.1.4** There is no golden qcow2, no image-conversion step, no
  `payloads/` directory, and no `virt-sysprep` or `zerofree` pass. Nothing is
  prebuilt for guests, so nothing needs de-identifying.
* **R-06.1.5** Guests that need a stateful disk — the LLM model volume, a
  per-project dev volume — receive it as an attached disk, formatted and
  mounted on first use, and tolerate its absence at install time so the guest
  still installs when the volume is not yet attached.

### R-06.2 The host renders the seed at guest-creation time

* **R-06.2.1** The committed seed templates carry placeholder tokens only. The
  host substitutes them immediately before creating each VM, from values that
  exist only on the host.
* **R-06.2.2** Substitution covers: the login password hash, the operator
  public key, the guest-identity public key, the username, full name, UID and
  GID, and the release reference.
* **R-06.2.3** The desktop seed additionally receives two private key
  placeholders, base64-encoded. **No other guest receives a private key
  half.** A dev VM is a place where untrusted code runs; a fleet-control
  private key on one is a fleet-control compromise.
* **R-06.2.4** The host **fails** if any placeholder token survives
  substitution, and reports which. A surviving token ships a guest with no
  login hash, no operator key, or a username that is literally
  `__PERSONALIZATION_USERNAME__` — each of which presents as a successful
  install that nobody can log in to.
* **R-06.2.5** Substitution aborts if any required identity variable is unset,
  naming the variable (Spec 05 §R-05.1.4).
* **R-06.2.6** Values substituted into a seed are escaped so that a yescrypt
  hash, an email address or a key survives intact.

### R-06.3 Guest identity comes from two keys, both installed from the seed

* **R-06.3.1** Every guest trusts two public keys: the operator's, from
  `keys/host_os_ed25519.pub`, and the guest-identity public key generated on
  the host at install time.
* **R-06.3.2** Because password authentication is disabled for SSH, a guest
  that lacks a trusted key has **no working SSH authentication method at
  all**. A seed that fails to inject a key produces a guest that is reachable
  only by console.
* **R-06.3.3** The seed writes the desktop's private keys after creating the
  destination directory, because a redirect into a directory that does not yet
  exist fails. This write runs in a different boot stage from the one that
  creates the user's SSH configuration, so the order cannot be assumed.
* **R-06.3.4** The desktop **hard-fails** first boot if either seeded private
  key is missing or is not a valid private key. `devctl` is unusable without
  them, and a wrapper that fails later, on first use, gives the operator no
  indication that the install was incomplete.
* **R-06.3.5** The desktop's first boot also hard-fails if its authorised-keys
  entry is missing, for the same reason.

### R-06.4 Guest `root` is locked by every seed

* **R-06.4.1** Every seed explicitly locks `root`, rather than relying on the
  installer's default.
* **R-06.4.2** No seed performs any other operation on guest `root`. An
  unlock somewhere in a `late-commands` block is invisible in the install log
  and yields a root shell on a VM whose purpose is to contain untrusted work.

### R-06.5 Guest creation is idempotent

* **R-06.5.1** A VM that already exists is not recreated, and a VM that is
  already running is not restarted.
* **R-06.5.2** A VM that is already a template is left as a template.
* **R-06.5.3** Every fragment is safe to re-run after an interrupted first
  boot. Recovery from a partial provision is a re-run, not a reinstall.

### R-06.6 Staged private keys are destroyed once used

* **R-06.6.1** The host stages the private key halves in a root-only location
  for the duration of seed assembly, and **destroys the staged copies** once
  every seed is built — and only after the loop, never inside it, so a
  failure part-way does not leave later guests unseeded.
* **R-06.6.2** The canonical keypairs under the host's root-only key directory
  are **retained**, so a re-provision is idempotent. Destroying them would make
  the second run generate different keys, leaving keys already trusted by a
  guest that no longer match the ones it will present.
* **R-06.6.3** Failure to destroy a staged key is fatal. A cleanup step that
  fails silently leaves a fleet-control private key on disk indefinitely.

### R-06.7 Provenance of every input

| Input | Source | Transport |
|---|---|---|
| Host install ISO | Built locally | USB, one-time |
| Login password hash | Rendered into the ISO's first-boot bootstrap | USB |
| Root password hash | Rendered into the answer file | USB |
| Host provisioner | This repository at the pinned reference | Network, first boot |
| Guest seed templates | This repository at the pinned reference | Network, at guest creation |
| Guest first-boot scripts | This repository at the pinned reference | Network, guest first boot |
| Ubuntu ISOs | `releases.ubuntu.com` | Network, at guest creation |
| Third-party packages and images | Official upstreams | Network |

* **R-06.7.1** Every artifact in this table is either authored in this
  repository or fetched from the official upstream for that software
  (Spec 00 §R-00.7).
* **R-06.7.2** The host and every guest use the same release reference. A guest
  seeded from a different tree than the host that created it will fetch
  first-boot scripts that do not match the seed it was given.

## 3. Invariants

* I-06.1 No credential is committed, and no credential transits a URL.
* I-06.2 No guest receives a private key half except the desktop, and only
  there as the two named control keys.
* I-06.3 Guest `root` is locked in every guest.
* I-06.4 No prebuilt guest image exists.
* I-06.5 A seed that would boot unusable is rejected before the VM is created.
* I-06.6 Re-running guest creation is safe.

## 4. Acceptance

| # | Check |
|---|---|
| A-06.1 | The three guests install unattended from an unmodified official Ubuntu ISO plus a host-assembled seed, with no interactive input. |
| A-06.2 | Each guest's `cloud-init` status reports success and the account from Spec 05 exists with the configured UID, GID, home and shell. |
| A-06.3 | A deliberately misconfigured identity variable aborts guest creation and names the variable; no VM is created. |
| A-06.4 | No rendered seed contains a surviving placeholder token. |
| A-06.5 | The desktop seed carries both private-key placeholders; the LLM and dev seeds contain no private-key placeholder. |
| A-06.6 | A yescrypt hash, an email address and a public key all survive rendering byte-for-byte. |
| A-06.7 | In every guest, `passwd -S root` reports `L`, and the personalization account is the only unlocked login. No seed contains any other root-credential operation. |
| A-06.8 | The desktop can `ssh` to the dev template by name over both the public and the guest-identity key. Withholding a seeded key reproduces the first-boot hard failure. |
| A-06.9 | Re-running guest creation creates nothing new and restarts nothing. |
| A-06.10 | After a completed run, the staged private key files do not exist, and the canonical keypairs under the host's key directory do. |
| A-06.11 | A guest with no attached stateful disk still installs and boots. |
| A-06.12 | The host and all guests report the same release reference. |
| A-06.13 | A committed seed template contains a real hash or a real key: both the pre-commit hook and the static test reject the commit. |

## 5. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Sourcing policy, pinning and reproducibility |
| Spec 01 | Fragment ordering; the host's own install media and bootstrap |
| Spec 02 | Desktop seed content and first-boot behaviour |
| Spec 03 | LLM seed content, data-volume contract, first-boot stack install |
| Spec 04 | Dev seed content, toolchain images, wrapper scripts |
| Spec 05 | Identity variables, the two-hash split, key injection rules |
| Spec 07 | `vmctl` and guest-identity keypair generation; the template conversion gate |
| Spec 09 | Seed placeholder, YAML validity and credential-split tests |
