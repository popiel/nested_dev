# Building the Nested Dev Stack

Step-by-step instructions for producing the host installer ISO and
deploying the full nested virtualization stack. Guest VMs are created
automatically by the host — no custom guest ISOs are required for the
standard workflow.

## Prerequisites

A Linux x86_64 host (or VM) with:

| Tool | Package | Purpose |
|---|---|---|
| `wget` | `wget` | ISO downloads |
| `sha256sum` | `coreutils` | ISO integrity verification |
| `mkpasswd` | `whois` | Generating the login password hash (one-time) |
| `proxmox-auto-install-assistant` | see below | Official ISO preparation tool |
| `docker` *(optional)* | Docker Desktop / engine | WSL/alternative carrier for the assistant |

### Getting `proxmox-auto-install-assistant`

You need this tool **either natively or via Docker**. If neither is
available, `build-iso.sh` will tell you exactly what to install.

**Option A — Native install (PVE host, Debian, or compatible):**

```bash
wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -O /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg] \
    http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install-repo.list
apt-get update && apt-get install -y proxmox-auto-install-assistant
```

**Option B — Docker (WSL, macOS, any host):**

No extra installs needed — `build-iso.sh` auto-detects Docker and pulls
the container on first run. The in-repo Dockerfile
(`provision/host/Dockerfile.autoinstall-assistant`) builds from Debian
trixie + the official PVE repo. Requires Docker Desktop or Docker Engine.

### Install helper packages in one shot (native path)

```bash
sudo apt-get install -y wget whois proxmox-auto-install-assistant
```

## One-time setup

### 1. Fork the repository

1. Fork `popiel/nested_dev` on GitHub to your own account.
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-user>/nested_dev.git
   cd nested_dev
   ```
3. Add the upstream remote for syncing:
   ```bash
   git remote add upstream https://github.com/popiel/nested_dev.git
   ```

### 2. Personalize

Edit `provision/personalization.sh` with your identity:

| Variable | Your value |
|---|---|
| `PERSONALIZATION_USERNAME` | Linux username for all VMs |
| `PERSONALIZATION_FULLNAME` | Full name (used in git config, realname) |
| `PERSONALIZATION_EMAIL` | Email (used in git config) |
| `PERSONALIZATION_UID` | UID (default `1401`; change only if it conflicts) |
| `PERSONALIZATION_GID` | GID (default `1401`) |
| `PERSONALIZATION_REPO` | Your GitHub `<user>/nested_dev` |
| `PERSONALIZATION_TAG` | Release tag (see tagging protocol below) |

No other files need editing — all build scripts and first-boot scripts
source this shared config.

The first dev VM (`dev-nested` for working on this repo) is created via
`devctl add nested` from the desktop after provisioning completes
([Spec 08](specs/08-nested-dev-repo-vm.md)).

### 3. Generate password hashes

Two distinct credentials, in two files, so neither can be mistaken for the
other. Generate yescrypt hashes and store them locally (never committed):

```bash
# Login password for the personalization account — host and all three guests
mkpasswd -m yescrypt > keys/personalization-password-hash
chmod 600 keys/personalization-password-hash

# Separate console/break-glass password for PVE root on the host only
mkpasswd -m yescrypt > keys/root-password-hash
chmod 600 keys/root-password-hash
```

Neither hash reaches GitHub; both are read at build time and embedded in the
host ISO only.

**`keys/root-password-hash`** is substituted into the answer file's
`root-password-hashed` field, so the installer writes it straight to the host
root account. It goes nowhere else — not into the guests, not onto disk
anywhere the provisioner can read it.

**`keys/personalization-password-hash`** travels in the first-boot bootstrap
(`--on-first-boot`, `source = "from-iso"`), which does two things with it:
creates the `${PERSONALIZATION_USERNAME}` account on the host — sudo group,
login password, plus the operator SSH key — and persists it to
`/root/.personalization-password-hash` for `frag/30` to inject into guest
user-data at VM creation time (Spec 06).

The host is the only place a personal password is ever set for root: guest
`root` is explicitly locked (`passwd -l root` in each seed), and the
personalization account is the only login on the host and in every guest.

### 4. Verify the SSH key

A public SSH key is committed at `keys/host_os_ed25519.pub`. If you want
to use your own key, replace it before building the host ISO. The
corresponding private key must be available on your workstation for SSH
access to the host and desktop VM.

### 5. Enable the git hook (recommended)

A pre-commit hook prevents accidental commits of real password hashes in
`user-data` files:

```bash
git config core.hooksPath .githooks
```

## Tagging protocol

Tags mark a known-good configuration. The tag is recorded in every build
manifest and first-boot script header for traceability.

### Tag format

```
host_os_v<major>.<minor>
```

| Example | Meaning |
|---|---|
| `host_os_v0.1` | First release — initial host + guest setup |
| `host_os_v0.2` | Incremental update (new package, config change) |
| `host_os_v1.0` | Stable baseline for production use |

### Creating a new tag

1. Make changes, commit, verify the host ISO builds.
2. Update `PERSONALIZATION_TAG` in `provision/personalization.sh`:
   ```bash
   PERSONALIZATION_TAG="host_os_v0.2"
   ```
3. Commit the tag change.
4. Create and push the git tag:
   ```bash
   git tag host_os_v0.2
   git push origin host_os_v0.2
   ```

Tags are **immutable** — once an ISO is built from a tagged commit, that
commit is never modified. A new tag is created for any change that affects
the built images.

### Syncing with upstream

If you forked the repo, pull updates from upstream:

```bash
git fetch upstream
git merge upstream/main
```

After merging, re-verify your personalization in `provision/personalization.sh`
and rebuild if needed.

## Build (standard workflow)

The standard workflow builds only the host ISO. Guest VMs are created
automatically by the host's first-boot provisioning.

### Step 1 — Build host ISO

```bash
provision/host/build-iso.sh
```

No `sudo` required — the script runs unprivileged and delegates ISO
preparation to the assistant (native or Docker).

Output: `output/proxmox-ve_9.2-1_auto.iso`

This ISO contains:
- PVE 9.2 autoinstall answer file (personalized with your SSH key)
- Root password hash (via `root-password-hashed`; host root only)
- First-boot bootstrap (embedded via `--on-first-boot`, carrying the
  personalization password hash and the account-creation block)
- First-boot provisioner (fetched from GitHub at install time)
- UEFI + BIOS boot (handled by `proxmox-auto-install-assistant prepare-iso`)

The build fails loudly if the ISO is missing or empty. `prepare-iso` can
exit 0 after printing its own errors, so the script treats the presence of
a non-empty `proxmox-ve_9.2-1_auto.iso` as the only trustworthy success
signal — it will never print `=== Build complete ===` or write a
`MANIFEST` entry for a build that produced no artifact.

### Running from Git Bash (Windows)

`build-iso.sh` can be run directly from Git Bash on Windows, including the
Docker path. This works because the script disables MSYS argument
conversion for every `docker` invocation and pre-converts host paths with
`cygpath`:

```bash
provision/host/build-iso.sh
```

> **Historical pitfall.** Earlier versions passed raw POSIX paths to
> `docker.exe`. The MSYS runtime rewrote them, so container-side arguments
> such as `/work` became `C:/Program Files/Git/work`, and the multi-colon
> bind-mount spec `.../output/iso:/iso:ro` was shredded (its `o:` read as a
> Windows drive letter). The assistant then operated on nonexistent files
> and exited 0. If you see stray directories named `output;C`,
> `output/iso;C`, or `output/build-work;C` in the repo, they are leftovers
> from that failure mode and can be deleted — they are always empty.

WSL2 and native Linux work without any of this. Use them if you have them.

### Step 2 — Install PVE on bare metal

1. Write the ISO to a USB stick:
   ```bash
   dd if=output/proxmox-ve_9.2-1_auto.iso of=/dev/sdX bs=4M status=progress
   ```
2. Boot the USB on the target machine (UEFI or legacy BIOS).
3. PVE autoinstall runs unattended. On first boot, the host:
   - Installs `root` with the hash from `keys/root-password-hash`
   - Creates the `${PERSONALIZATION_USERNAME}` account (UID/GID from
     `provision/personalization.sh`) with the login password from
     `keys/personalization-password-hash`, `sudo` membership, and the
     operator SSH key — PVE's schema has no non-root user field, so this is
     the only place it can happen
   - Persists that login hash to `/root/.personalization-password-hash`
   - Fetches the provisioner from GitHub, and preserves
     `keys/host_os_ed25519.pub` into `/root/provision/keys/` so it can be
     injected into the guest seeds
   - Configures networking, GPU passthrough, dnsmasq, iptables
   - Creates the `vmctl` user + control keypair, and the guest identity
     keypair (private half → desktop, public half → host and all guests)
     (Spec 07)
   - Fetches user-data templates from GitHub
   - Injects the login hash, both public keys, and the desktop's two
     private keys into the templates
   - Shreds the staged private key copies once the seeds are built
   - Builds NoCloud seed ISOs (Spec 06)
   - Creates and starts Desktop (100) + LLM (101)
   - Creates dev-template (102), provisions it, converts to PVE template
   - Guest autoinstall runs, then first-boot scripts fetch from GitHub

### Step 3 — Verify

```bash
# SSH to host (operator key works for both accounts)
ssh -p 2222 root@<lan-ip>
ssh <you>@<lan-ip>

# Accounts: personalization user has sudo; root has its own password.
# Neither guest account has a root password at all.
id <you> && sudo -n true && echo "sudo ok"

# Check guest VMs
qm status 100   # desktop (running)
qm status 101   # llm (running)
qm status 102   # dev-template (template, never started)

# Check first-boot logs
tail -f /var/log/pve-firstboot.log

# From the desktop (via RDP or SSH):
devctl list     # shows desktop, llm, dev-template
```

Desktop and LLM should be running. Dev-template (102) is a PVE template
(never auto-started). First-boot scripts install remaining packages
(NVIDIA drivers, Docker, Ollama, etc.) — this takes several minutes.

## Network topology

```
  LAN 192.168.14.0/24
       |
  [ Physical NIC ]  DHCP from router
       |
  [ PVE Host ]      192.168.14.x (management)
       |             192.168.100.1/24 (vmbr0, dnsmasq)
       |
       +--- Desktop      192.168.100.100  (bastion, display, SSH jump)
       +--- LLM          192.168.100.101  (Ollama, GPU passthrough)
       +--- Dev template 192.168.100.102  (PVE template, clone source)
       +--- Dev nested   192.168.100.103  (nested_dev repo, on demand)
       +--- Dev <name>   192.168.100.103+ (other projects, on demand)
```

## Upgrading Ubuntu version

Edit `provision/ubuntu-release.conf` — change `UBUNTU_VERSION` and, if
Ubuntu has rotated its signing key, replace `keys/ubuntu-release-key.asc`.
Guest user-data templates on GitHub will use the new version automatically
on next host first-boot.

## Build output

All artifacts land in `output/` (gitignored):

```
output/
  iso/                                   # Downloaded upstream ISOs
  build-work/                            # Working files (answer file, etc.)
  proxmox-ve_9.2-1_auto.iso             # Host installer ISO (UEFI + BIOS)
  MANIFEST                               # Build metadata (versions, hashes)
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `Missing: wget` | `sudo apt-get install wget` |
| `No proxmox-auto-install-assistant found` | See [Getting `proxmox-auto-install-assistant`](#getting-proxmox-auto-install-assistant) above |
| `Missing: keys/personalization-password-hash` | Run `mkpasswd -m yescrypt > keys/personalization-password-hash` |
| `Missing: keys/root-password-hash` | Run `mkpasswd -m yescrypt > keys/root-password-hash` — required by the answer file's `root-password-hashed` |
| Host has only a `root` account after install | The first-boot bootstrap creates the personalization account; check `/var/log/pve-firstboot-bootstrap.log`. On an already-installed host, re-run that step or the block in `provision/host/first-boot.sh` §2 by hand |
| ISO download fails or 0-byte file | Check internet; delete `output/iso/proxmox-ve_9.2-1.iso` and re-run |
| ISO SHA256 mismatch after re-download | Verify file wasn't truncated; re-run from a fresh `output/iso/` directory |
| Docker image build fails | Ensure Docker is running; check `docker build` output for dependency errors |
| Build fails on WSL | Use Docker path (default if Docker is available) or install the assistant natively via the PVE apt repo |
| `=== Build complete ===` printed but no ISO in `output/` | Should be impossible — the build now aborts on a missing or empty ISO. If you hit this, the script is older than the fix; `git pull`. Check for stray `output;C`-style directories, which indicate a build that ran under Git Bash with MSYS conversion active |
| `Error: Opening answer file "C:/Program Files/Git/work/..."` | MSYS rewrote the container path. Run under WSL2/native Linux, or use a `build-iso.sh` that includes the `docker_noconv` opt-out |
| Guest VMs not created | Check `/var/log/pve-firstboot.log`; ensure host has internet for GitHub fetches |
| Desktop/LLM created but not running | Run `qm start <vmid>` manually; check serial console via `qm terminal <vmid>` |
| Dev template not converted to template | Check provisioning gate in `/var/log/pve-firstboot.log`; manually: `qm guest exec 102 -- cloud-init clean` + `qm shutdown 102` + `qm template 102` |
| Dev template exists but can't start | Expected — it's a PVE template. Use `devctl add <project>` to clone it |
| Dev VM not created by devctl | Check `/var/log/nested-dev-vmctl.log` on host; verify `devctl list` shows template 102 |
| Guest first-boot stuck | Check `/var/log/desktop-firstboot.log` (or llm/dev variant); ensure host MASQUERADE is working |
| PVE validation error on answer file | Ensure `keys/root-password-hash` exists; the answer requires exactly one of `root-password` or `root-password-hashed` |
| `Guest VMs not created` after a rename | `frag/30` aborts if `/root/.personalization-password-hash` is missing on the host — check the bootstrap log and re-run `systemctl start pve-firstboot` |

## Addendum: diagnosing a red CI gate

Every push and pull request runs the full suite on a clean Ubuntu runner
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)): checkout, system
dependencies from apt, the pinned `bats`/`shellcheck` from
`tests/wsl-setup.sh`, then `tests/run.sh` over all tiers. A red gate means
the suite and the runner disagree about something — the runner is a
different machine than the ones the suite was last green on, so treat the
difference as evidence, not noise.

### Reading a failed run

In the repository's Actions tab, open the failed run and expand the
**Run test suite** step:

- One summary line per suite (pass/fail with counts), in run order.
- Below it, the full TAP output of each failing suite, including the
  failing assertion — a failing suite is printed in full, so there is no
  separate log to hunt for.
- Then the `=== timing ===` report and the `=== result ===` block of
  `key=value` pairs.

For searching, download the run's log archive (the run page offers it as a
zip) and search the step file for `not ok`. The per-suite summary lines
name the failing suites; work outward from the first one — later failures
are often cascades of an earlier suite's breakage (a static content failure
can resurface inside meta-suites that execute the harness itself).

### Environment deltas to check first

Most CI-only reds have been one of these:

- **Tool versions.** Developers pin `bats`/`shellcheck` via
  `tests/wsl-setup.sh`; CI installs the same pins. If a failure smells
  version-shaped (changed diagnostics, new findings on untouched code,
  TAP shapes the parser doesn't recognize), verify both sides resolve the
  same versions before touching suite code.
- **`/bin/sh` is dash on the runner.** Any shell invoked without an
  explicit interpreter, or via `/bin/sh`, runs under dash there — while a
  dev machine may silently provide bash as `sh`. Bash scripts must name
  `bash` at every invocation site, including usage documentation.
- **Optional tools are present on CI.** Checks that skip locally for lack
  of `dnsmasq`/`iptables-restore`/etc. *run* on the runner — against the
  runner's kernel and privileges, not yours. A check that never executed
  locally can fail there on content no one ever validated (overlong
  fixture values, kernel-gated operations). Capability probes with skip
  fallbacks beat identity checks (`root` vs not) for these.
- **Clean-machine assumptions.** The runner has no prior timing history,
  no host quirks, no warm caches. Anything the suite reads outside the
  repo and its temp dirs is suspect on first sight.

### Fixing direction

Fix the code or the test, not the gate: keep the workflow running the full
suite on the pinned runner. Version pins move forward deliberately (see the
pin comment in `ci.yml`), never by accepting whatever apt happens to carry.
