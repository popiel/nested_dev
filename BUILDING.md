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

### 3. Generate a password hash

All three guest VMs share the same login password. Generate a yescrypt hash
and store it locally (never committed):

```bash
mkpasswd -m yescrypt > keys/password-hash
chmod 600 keys/password-hash
```

The hash is embedded in the host ISO at build time via the
`root-password-hashed` answer field. The host persists it to
`/root/.password-hash` during PVE install, then injects it into
guest user-data at VM creation time (Spec 06). The hash never reaches
GitHub.

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
- Password hash (via `root-password-hashed`, embedded for guest provisioning)
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
   - Persists the password hash to `/root/.password-hash`
   - Fetches the provisioner from GitHub
   - Configures networking, GPU passthrough, dnsmasq, iptables
   - Creates `vmctl` user + control keypair (Spec 07)
   - Fetches user-data templates from GitHub
   - Injects password hash + vmctl key into templates
   - Builds NoCloud seed ISOs (Spec 06)
   - Creates and starts Desktop (100) + LLM (101)
   - Creates dev-template (102), provisions it, converts to PVE template
   - Guest autoinstall runs, then first-boot scripts fetch from GitHub

### Step 3 — Verify

```bash
# SSH to host
ssh -p 2222 root@<lan-ip>

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
| `Missing: keys/password-hash` | Run `mkpasswd -m yescrypt > keys/password-hash` |
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
| PVE validation error on answer file | Ensure `keys/password-hash` exists; the answer requires exactly one of `root-password` or `root-password-hashed` |
