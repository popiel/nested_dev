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
| `xorriso` | `xorriso` | ISO repackaging |
| `bsdtar` | `libarchive-tools` | ISO extraction |
| `mkpasswd` | `whois` | Generating the login password hash (one-time) |

Install in one shot on Ubuntu/Debian:

```bash
sudo apt-get install -y wget xorriso libarchive-tools whois
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

### 3. Generate a password hash

All three guest VMs share the same login password. Generate a yescrypt hash
and store it locally (never committed):

```bash
mkpasswd -m yescrypt > keys/password-hash
chmod 600 keys/password-hash
```

The hash is embedded in the host ISO at build time. The host persists it
to `/root/.password-hash` during PVE install, then injects it into
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
sudo provision/host/build-iso.sh
```

Output: `output/proxmox-ve_9.2-1_auto.iso`

This ISO contains:
- PVE 9.2 autoinstall answer file (personalized with your SSH key)
- Password hash (from `keys/password-hash`, embedded for guest provisioning)
- First-boot provisioner (fetched from GitHub at install time)

### Step 2 — Install PVE on bare metal

1. Write the ISO to a USB stick:
   ```bash
   dd if=output/proxmox-ve_9.2-1_auto.iso of=/dev/sdX bs=4M status=progress
   ```
2. Boot the USB on the target machine.
3. PVE autoinstall runs unattended. On first boot, the host:
   - Persists the password hash to `/root/.password-hash`
   - Fetches the provisioner from GitHub
   - Configures networking, GPU passthrough, dnsmasq, iptables
   - Fetches user-data templates from GitHub
   - Injects password hash into templates
   - Creates and starts guest VMs (Desktop, LLM, Dev)
   - Guest autoinstall runs, then first-boot scripts fetch from GitHub

### Step 3 — Verify

```bash
# SSH to host
ssh -p 2222 root@<lan-ip>

# Check guest VMs
qm status 100   # desktop
qm status 101   # llm
qm status 102   # dev-template

# Check first-boot logs
tail -f /var/log/pve-firstboot.log
```

Guest VMs should be running. First-boot scripts install remaining
packages (NVIDIA drivers, Docker, Ollama, etc.) — this takes several
minutes on first boot.

## Network topology

```
  LAN 192.168.14.0/24
       |
  [ Physical NIC ]  DHCP from router
       |
  [ PVE Host ]      192.168.14.x (management)
       |             192.168.100.1/24 (vmbr0, dnsmasq)
       |
       +--- Desktop   192.168.100.100  (bastion, display, SSH jump)
       +--- LLM       192.168.100.101  (Ollama, GPU passthrough)
       +--- Dev       192.168.100.102+ (Docker, per-project)
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
  proxmox-ve_9.2-1_auto.iso             # Host installer ISO
  MANIFEST                               # Build metadata (versions, hashes)
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `Missing: xorriso` | `sudo apt-get install xorriso` |
| `Missing: keys/password-hash` | Run `mkpasswd -m yescrypt > keys/password-hash` |
| Build fails on WSL/older Ubuntu | Use a Ubuntu 24.04+ host; older distros may lack yescrypt support in `mkpasswd` |
| Guest VMs not created | Check `/var/log/pve-firstboot.log`; ensure host has internet for GitHub fetches |
| Guest VMs created but not running | Run `qm start <vmid>` manually; check serial console via `qm terminal <vmid>` |
| Guest first-boot stuck | Check `/var/log/desktop-firstboot.log` (or llm/dev variant); ensure host MASQUERADE is working |
