# Spec 08 — Nested dev repo development VM

Status: Draft (new)
Pinned versions: Ubuntu Server **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**
Depends on: Spec 01 (host), Spec 04 (dev image), Spec 05 (personalization),
            Spec 06 (guest provisioning), Spec 07 (dev fleet lifecycle)

## 1. Purpose and scope

Produce a dedicated dev VM (**VM 103, `dev-nested`**) specifically for working on
the `popiel/nested_dev` repository. This VM hosts the build toolchain for
producing host ISOs, golden images, and acceptance-testing artifacts — all
delegated to a purpose-built Docker container (`dev-nested-build`).

In scope: VM 103 profile (name, resources, storage), `dev/docker/Dockerfile.nested`
(container image), wrapper scripts (`nested`, `dev-refresh-images`), per-project
storage conventions, image rebuild and refresh procedures, acceptance. Out of
scope: host provisioning (Spec 01), other dev VM fleets (Spec 07), desktop
control (Spec 07), the generic dev VM toolchain (Spec 04 §3–§5.5).

## 2. Design decisions

| Decision | Default | Rationale |
|---|---|---|
| VM identity | VM 103 `dev-nested`, hostname `lychee-dev-nested` | First project clone of dev-template; deterministic from Spec 07 naming convention |
| Resources | 8192 MB RAM, 4 cores, CPU host | Same as generic dev VM; sufficient for ISO builds |
| Storage | 40 GB OS (scsi0) + 100 GB data (`scsi1`, per-project volume for `output/` and ISO cache) | Build ISOs can be ~1 GB; data volume keeps workspace separate from OS |
| Build container | `dev-nested-build` (new image) | Runs as root (required by `build-iso.sh`); bind-mounts repo checkout + keys + output |
| Base image | `ubuntu:26.04` | Matches host OS; `xorriso` 2.x available in archive |
| Run-as | Root inside container; ownership normalized after build | `build-iso.sh` asserts `id -u == 0`; ownership fix handles host uid mapping |
| Repo location | `/work/nested_dev` (bind-mounted from `scsi1`) | Per-project volume; workspace persists across clones |
| Keys location | `/work/nested_dev/secrets/` on the data volume (symlinked to `keys/` inside the repo) | `keys/password-hash` is gitignored; lives only on the data volume |
| Output location | `/work/nested_dev/output/` (data volume) | gitignored; build artifacts persist here |
| Golden image rebuild | Operator-run `refresh-guests.sh` or `devctl` + manual; no automatic rebuild | REF changes require intentional action; documented procedure |
| Tool image refresh | `dev-refresh-images` script (shared across all dev VMs) | Rebuilds with `--pull`; logs digests to `MANIFEST` |

## 3. Build inputs (new files)

| File | Description |
|---|---|
| `dev/docker/Dockerfile.nested` | `dev-nested-build` container: Ubuntu 26.04, wget, xorriso, libarchive-tools, whois, git, curl, gnupg, ca-certificates, openssh-client, python3 |
| `dev/tools/nested` | Wrapper script: `build`, `verify`, `refresh`, `keys-status` verbs |
| `dev/tools/dev-refresh-images` | Refresh all tool images + dev-nested-build |
| `dev/tools/dev-nested-provision.sh` | One-time provisioner for VM 103: clone repo, set up secrets, build config |

## 4. VM 103 profile

Created via `devctl add nested` from the desktop (Spec 07), or manually:

```bash
# From desktop via devctl:
devctl add nested

# Or from host (manual):
qm clone 102 103 --name dev-nested --full
qm set 103 --memory 8192 --cores 4 --cpu host
qm set 103 --scsi1 local-lvm:100,size=100G
qm set 103 --net0 virtio=52:54:00:00:02:67,bridge=vmbr0,firewall=1
```

On first boot (after `devctl start 103`), the cloned VM's generic dev first-boot
script (`dev-firstboot.sh`) runs: Docker CE, workspace `/work`, git config, base
image pulls, wrapper scripts, cache dirs, firewall. The per-project provisioner
then handles the nested_dev-specific setup.

## 5. Container image: `dev-nested-build`

### 5.1 `dev/docker/Dockerfile.nested`

```dockerfile
FROM ubuntu:26.04

# Build dependencies for nested_dev ISO builder
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        wget \
        xorriso \
        libarchive-tools \
        whois \
        git \
        curl \
        gnupg \
        ca-certificates \
        openssh-client \
        python3 \
        file \
        rsync \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
ENTRYPOINT ["bash"]
```

**Key properties:**
- Runs as **root** (required by `build-iso.sh` which asserts `id -u == 0`).
- Packages: `wget` (ISO downloads), `xorriso` (ISO repackaging), `libarchive-tools`
  (`bsdtar` for ISO extraction), `whois` (`mkpasswd` for password hash generation),
  `git`, `curl`, `gnupg` (key verification), `openssh-client`, `python3`, `file`,
  `rsync`.
- **No** `proxmox-auto-install-assistant` (requires PVE repo; optional; `build-iso.sh`
  tolerates its absence).
- `ENTRYPOINT ["bash"]` — wrapper scripts pass commands via `-c '...'`.

### 5.2 Build invocation pattern

The wrapper script mounts the repo checkout, keys, and output:

```bash
docker run --rm \
  -v "${NESTED_DEV}:/work/nested_dev" \
  -v "${NESTED_DEV}/output:/work/nested_dev/output" \
  -w /work/nested_dev \
  dev-nested-build \
  -c 'provision/host/build-iso.sh'
```

After the build, ownership of output files is normalized:

```bash
chown -R "${USER}:${USER}" "${NESTED_DEV}/output/" "${NESTED_DEV}/keys/"
```

## 6. Wrapper scripts

### 6.1 `nested` — build toolchain wrapper

Installed to `~/.local/bin/nested` by `dev-firstboot.sh` or the per-project
provisioner.

```bash
#!/usr/bin/env bash
# nested — wrapper for popiel/nested_dev build toolchain
set -euo pipefail

DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-nested-build"
NESTED_DEV="${HOME}/work/nested_dev"

# Ensure repo checkout exists
if [ ! -d "${NESTED_DEV}/.git" ]; then
    echo "[nested] Repository not found at ${NESTED_DEV}. Clone or mount it first."
    exit 1
fi

# Ensure data volume mounted (output/ writable)
if ! mountpoint -q /work 2>/dev/null; then
    echo "[nested] Warning: /work is not a mount point. Output may not persist."
fi

# Ensure image exists; build on first use
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "[nested] Building ${IMAGE} (first run)..."
    docker build --tag "${IMAGE}" -f "${DOCKER_DIR}/Dockerfile.nested" "${DOCKER_DIR}"
fi

# Parse verb
VERB="${1:-help}"
shift || true

case "$VERB" in
    build)
        echo "[nested] Building host ISO..."
        docker run --rm \
          -v "${NESTED_DEV}:/work/nested_dev" \
          -w /work/nested_dev \
          -e DEBIAN_FRONTEND=noninteractive \
          "${IMAGE}" \
          -c 'provision/host/build-iso.sh'
        chown -R "${USER}:${USER}" "${NESTED_DEV}/output/" 2>/dev/null || true
        echo "[nested] Build complete. Output in ${NESTED_DEV}/output/"
        ;;

    verify)
        echo "[nested] Verifying answer file..."
        docker run --rm \
          -v "${NESTED_DEV}:/work/nested_dev" \
          -w /work/nested_dev \
          "${IMAGE}" \
          -c 'cd provision/host && cat answer-host.toml' \
          && echo "[nested] Answer file OK"
        ;;

    refresh)
        echo "[nested] Refreshing dev-nested-build image..."
        docker build --pull --no-cache --tag "${IMAGE}" \
          -f "${DOCKER_DIR}/Dockerfile.nested" "${DOCKER_DIR}"
        echo "[nested] Refreshed. New digest:"
        docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null || echo "  (local only, no registry digest)"
        ;;

    keys-status)
        echo "[nested] Checking keys..."
        if [ -f "${NESTED_DEV}/secrets/password-hash" ]; then
            echo "  password-hash: present"
        else
            echo "  password-hash: MISSING (generate with: mkpasswd -m yescrypt > ${NESTED_DEV}/secrets/password-hash)"
        fi
        for key in host_os_ed25519.pub ubuntu-release-key.asc; do
            if [ -f "${NESTED_DEV}/keys/${key}" ]; then
                echo "  ${key}: present"
            else
                echo "  ${key}: MISSING"
            fi
        done
        ;;

    help|*)
        echo "Usage: nested <command>" >&2
        echo "" >&2
        echo "Commands:" >&2
        echo "  build        Build the host autoinstall ISO" >&2
        echo "  verify       Verify the answer file" >&2
        echo "  refresh      Rebuild the dev-nested-build image from scratch" >&2
        echo "  keys-status  Check that required keys are present" >&2
        echo "  help         Show this help" >&2
        exit 1
        ;;
esac
```

### 6.2 `dev-refresh-images` — shared tool image refresh

Installed to `~/.local/bin/dev-refresh-images` by `dev-firstboot.sh`. Rebuilds
all tool images (java, scala, sbt, opencode, nested-build) with `--pull` and logs
digests.

```bash
#!/usr/bin/env bash
# dev-refresh-images — rebuild all dev tool images with latest base layers
set -euo pipefail

DOCKER_DIR="/opt/dev-docker"
MANIFEST="${HOME}/.local/share/dev-images-manifest"
mkdir -p "$(dirname "$MANIFEST")"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

log "=== Refreshing dev tool images ==="
echo "" >> "$MANIFEST"
echo "## Image refresh — $(date -Is)" >> "$MANIFEST"

IMAGES=(
    "dev-java:Dockerfile.java"
    "dev-scala:Dockerfile.scala"
    "dev-sbt:Dockerfile.sbt"
    "dev-opencode:Dockerfile.opencode"
    "dev-nested-build:Dockerfile.nested"
)

for entry in "${IMAGES[@]}"; do
    IFS=':' read -r TAG FILENAME <<< "$entry"
    log "Rebuilding ${TAG}..."
    if docker build --pull --tag "${TAG}" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        --build-arg PERSONALIZATION_UID="$(id -u)" \
        -f "${DOCKER_DIR}/${FILENAME}" "${DOCKER_DIR}" 2>&1; then
        DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${TAG}" 2>/dev/null || echo "local")
        log "  ${TAG}: ${DIGEST}"
        echo "${TAG}: ${DIGEST}" >> "$MANIFEST"
    else
        log "  ${TAG}: BUILD FAILED"
        echo "${TAG}: BUILD_FAILED" >> "$MANIFEST"
    fi
done

log "=== Refresh complete — digests saved to ${MANIFEST} ==="
cat "$MANIFEST" | tail -20
```

## 7. Per-project provisioner

### 7.1 `dev/tools/dev-nested-provision.sh` (run once on VM 103 first boot)

Handles the nested_dev-specific setup on top of the generic dev first-boot:

```bash
#!/usr/bin/env bash
# dev-nested-provision.sh — one-time nested_dev repo setup on VM 103
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a /var/log/nested-provision.log; }

NESTED_DEV="${HOME}/work/nested_dev"
SECRETS_DIR="${NESTED_DEV}/secrets"

# --- 1. Clone repo (if not already present) ---
if [ ! -d "${NESTED_DEV}/.git" ]; then
    log "Cloning popiel/nested_dev..."
    mkdir -p "$(dirname "${NESTED_DEV}")"
    git clone https://github.com/popiel/nested_dev.git "${NESTED_DEV}"
    log "Repository cloned"
fi

# --- 2. Set up secrets directory ---
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

# Ensure password hash exists (reminder only — operator must generate)
if [ ! -f "${SECRETS_DIR}/password-hash" ]; then
    log "WARNING: keys/password-hash not found."
    log "  Generate on the host: mkpasswd -m yescrypt > ${SECRETS_DIR}/password-hash"
    log "  Then copy to ${SECRETS_DIR}/password-hash on this VM."
fi

# Symlink secrets/ into keys/ for build-iso.sh compatibility
if [ -d "${NESTED_DEV}/keys" ] && [ ! -L "${NESTED_DEV}/keys" ]; then
    # keys/ is a real directory with .pub and .asc — overlay with secrets
    ln -sfn "${SECRETS_DIR}/password-hash" "${NESTED_DEV}/keys/password-hash"
    log "Symlinked secrets/password-hash into keys/"
fi

# --- 3. Data volume mount ---
if [ -b /dev/vdb ]; then
    if ! mountpoint -q /work 2>/dev/null; then
        if ! blkid /dev/vdb >/dev/null 2>&1; then
            mkfs.ext4 -F /dev/vdb
        fi
        mkdir -p /work
        mount /dev/vdb /work
        if ! grep -q "/dev/vdb /work" /etc/fstab; then
            echo "/dev/vdb /work ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
    fi
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" /work 2>/dev/null || true
    log "Data volume mounted at /work"
fi

# --- 4. Verify toolchain ---
log "Verifying build toolchain..."
for cmd in wget xorriso bsdtar mkpasswd git ssh docker; do
    if command -v "$cmd" >/dev/null 2>&1; then
        log "  $cmd: $(command -v "$cmd")"
    else
        log "  $cmd: MISSING"
    fi
done

# --- 5. First build smoke test (optional) ---
log "Provision complete. Run 'nested build' to produce the host ISO."
log "Run 'nested keys-status' to check required keys."
```

## 8. Image rebuild and refresh procedures

### 8.1 Dev tool images (all VMs)

All dev VMs share the same tool images (java, scala, sbt, opencode). The
`dev-nested-build` image is specific to VM 103 but follows the same pattern.

**Refresh a single image:**
```bash
docker build --pull --tag dev-java -f /opt/dev-docker/Dockerfile.java /opt/dev-docker
```

**Refresh all tool images:**
```bash
dev-refresh-images
```

**Digest tracking:** `dev-refresh-images` writes digests to
`~/.local/share/dev-images-manifest`. This file is local (not versioned)
and records when each image was last refreshed.

### 8.2 Dev template (VM 102)

The template is the clone source for all dev VMs. When the template needs
updating (e.g. new REF, changed packages):

**Option A — destroy and recreate (cleanest):**
```bash
# On the host (or via vmctl if frag/30 provides a rebuild verb):
qm destroy 102
# Re-run frag/30 guest creation for 102 (provisioning gate + template conversion)
```

**Option B — refresh the running template's first-boot state (faster):**
```bash
# From desktop or host:
qm start 102   # wait for provisioning
qm guest exec 102 -- bash -c 'cd /root && wget -qO- ... | bash'  # re-run first-boot
qm guest exec 102 -- cloud-init clean
qm shutdown 102
qm template 102
```

**Operator tool (host-side):** `provision/host/refresh-guests.sh` (shipped as
repo file) automates Option A with appropriate logging.

### 8.3 Nested dev builder image (VM 103)

Refresh on VM 103:
```bash
nested refresh
# or directly:
docker build --pull --no-cache --tag dev-nested-build \
  -f /opt/dev-docker/Dockerfile.nested /opt/dev-docker
```

### 8.4 Guest images under NoCloud

Since guest VMs install from the official Ubuntu ISO + NoCloud seed (Spec 06),
there are no golden qcow2 files to rebuild. The "image" that matters is the
**template VM 102**, which is rebuilt as described in §8.2.

When `PERSONALIZATION_REF` changes:
1. Update `provision/personalization.sh` with new REF.
2. Rebuild host ISO: `sudo provision/host/build-iso.sh`.
3. On existing host: run `refresh-guests.sh` or manually rebuild template 102.
4. `devctl` clones from the updated template.

### 8.5 Host ISO rebuild

```bash
sudo provision/host/build-iso.sh
```

Produces `output/proxmox-ve_9.2-1_auto.iso` with the new REF. The host's
`MANIFEST` records the resolved commit SHA.

## 9. Storage layout

VM 103 `dev-nested` storage:

```
scsi0 (OS disk, 40 GB):    Ubuntu Server 26.04 + Docker CE + toolchains
scsi1 (data volume, 100 GB): workspace mounted at /work
  /work/nested_dev/           git checkout of popiel/nested_dev
  /work/nested_dev/output/    build artifacts (ISO, MANIFEST)
  /work/nested_dev/secrets/   password-hash and other secrets (not in git)
  /work/nested_dev/keys/      symlinked to secrets/ for build-iso.sh
```

Per-project scsi1 volumes are created at clone time by the operator or
`vmctl-host add`:
```bash
qm set 103 --scsi1 local-lvm:100,size=100G
```

## 10. Network containment

VM 103 follows the generic dev VM firewall (Spec 04 §5 step 8):
- Default deny incoming and outgoing.
- Allow SSH inbound.
- Allow outbound 53, 80, 443 (DNS, HTTP, HTTPS for package repos and GitHub).
- Host iptables OUTPUT chain restricts dev egress at the host level.

The `build-iso.sh` workflow needs outbound HTTPS (GitHub, Ubuntu archive, PVE ISO
download) — satisfied by the allowlist.

Nested virtualization for acceptance testing (running PVE inside the dev VM)
requires `kvm_intel nested=1` (or AMD equivalent) on the **host** PVE.
This is an optional host configuration, not part of the dev VM provisioning.

## 11. Acceptance

* `devctl add nested` creates VM 103 (`dev-nested`, stopped); `devctl start 103`
  boots it; first-boot completes (Docker CE, toolchains installed).
* `devctl log 103` shows `/var/log/dev-firstboot.log` output.
* Inside VM 103: `nested keys-status` reports key presence/absence.
* Inside VM 103: `nested build` produces `output/proxmox-ve_9.2-1_auto.iso` with
  correct MANIFEST (requires `keys/password-hash`).
* Inside VM 103: `nested refresh` rebuilds `dev-nested-build` from upstream
  Ubuntu base; new digest logged.
* Inside VM 103: `dev-refresh-images` rebuilds all five tool images (java, scala,
  sbt, opencode, nested-build) with `--pull`; digests appended to manifest.
* `devctl ssh 103 nested build` runs the build remotely from the desktop.
* `devctl stop 103` gracefully shuts down the VM.
* Data volume persists across `devctl` stop/start cycles (`/work` remains mounted).
* Golden image rebuild: on the host, `refresh-guests.sh` destroys + recreates
  template 102; subsequent `devctl add` clones produce VMs with updated packages.
* `devctl ssh 103 git log --oneline -1` shows the cloned repo's HEAD.
