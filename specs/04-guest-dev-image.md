# Spec 04 — Guest: Dev VM image (Ubuntu Server 26.04, one project per VM)

Status: Draft (new; no predecessor — closes the `README.md` gap)
Pinned versions: Ubuntu Server **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**

## 1. Purpose and scope

Produce a golden QEMU disk (`dev-golden.qcow2`) for Proxmox **vm 102+**
(`dev-<project>`). Per `README.md`, each software dev VM hosts **only one
software project**, its network is **severally constrained**, and the VM is
**primarily disk storage + Docker engine** — all dev tasks (AI harness,
compiles, tests) run in **ephemeral Docker containers, often with
bind-mounted disk access**.

Neither `specs-mimo/` nor `specs-ds4/` specified this VM. This spec is new and
normative.

In scope: autoinstall `user-data`, Docker-only first boot, containerized dev
toolchain (Java 21, Scala, sbt, opencode), ephemeral wrapper-script pattern,
per-project cloning contract, bind-mount + network-containment conventions,
build/cleanup. Out of scope: project code itself, LLM serving (Spec 03),
desktop access (Spec 02), host wiring (Spec 01 §5.3).

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Server **26.04 LTS** (same ISO as Spec 03, SHA256 pinned) |
| GPUs | **None** — no `hostpci` on dev VMs; GPU work goes via Spec 03 APIs |
| Runtime | Docker CE only (no NVIDIA toolkit, no CUDA, no Ollama in image or first boot) |
| JDK | **21 LTS** (`eclipse-temurin:21-jre-jammy`) — required by Scala 3.x and sbt 1.10+ |
| Java/Scala | Coursier-managed inside containers; `dev-java` and `dev-scala` images |
| sbt | Official `sbtscala/sbt:1.10.7_2.13.15_3` image; `dev-sbt` wrapper |
| opencode | `node:20-slim` + npm global install; `dev-opencode` wrapper; config mount **read-only** |
| Workspace | `/work/<project>` on OS disk (or attached `scsi1` per-project volume); bind-mounted into ephemeral containers, never copied into images |
| Build caches | `~/.sbt`, `~/.ivy2`, `~/.cache/coursier` mounted into containers for incremental builds |
| Wrapper scripts | `/home/${PERSONALIZATION_USERNAME}/.local/bin/` (§05) in PATH via `.bashrc`; one script per tool |
| Network | Egress-deny default; allowlist only (Ubuntu archive + pinned upstreams + LLM-VM API peer); ingress SSH only |
| Account | `popiel` (§05), SSH-key-only; `docker` group membership |
| OS disk | **40 GB** virtio thin (project data beyond that → per-project `scsi1` volume) |
| Fleet | Golden `dev-golden.qcow2` cloned per project: `102=dev-<alpha>`, `103=dev-<beta>`, …; `200–249` remain reserved future |
| Identity | No machine-specific data in golden image |
| Git config | Global `user.name`/`user.email` per §05; set at first boot for `popiel` |

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-26.04-live-server-amd64.iso` | Official, same pin as Spec 03 |
| `dev/user-data/meta-data` | Empty |
| `dev/user-data/user-data` | Autoinstall (§4) |
| `dev/build-iso.sh` | Injects `autoinstall` param (same routes as Spec 02 §3) |
| `dev/dev-firstboot.sh` | Docker + base image pulls + wrapper scripts, fetched at `<REF>` |
| `dev/docker/Dockerfile.*` | Four Dockerfiles for tool images, embedded on ISO, built lazily |

### Container images (Dockerfiles in `dev/docker/`, built lazily by wrapper scripts)

| Image tag | Dockerfile | Base | Entry point | Purpose |
|---|---|---|---|---|
| `dev-java` | `Dockerfile.java` | `eclipse-temurin:21-jre-jammy` | `java` | Java 21 runtime via coursier-managed JDK |
| `dev-scala` | `Dockerfile.scala` | `coursier/jre:21` | `scala` | Scala REPL via coursier |
| `dev-sbt` | `Dockerfile.sbt` | `sbtscala/sbt:1.10.7_2.13.15_3` | `sbt` | sbt build tool |
| `dev-opencode` | `Dockerfile.opencode` | `node:20-slim` | `opencode` | opencode CLI (npm global install) |

Images are **not** built at first boot. Base images are pulled at first boot;
tool images are built lazily by wrapper scripts on first use (§5.5). Each
Dockerfile accepts `ARG PERSONALIZATION_USERNAME` to create a matching user
inside the container, avoiding bind-mount ownership mismatches.

### Wrapper scripts (in `/home/${PERSONALIZATION_USERNAME}/.local/bin/`)

One script per tool; pattern documented in §5.5.

## 4. `user-data` (representative, 26.04)

User identity values sourced from §05 via `provision/personalization.sh`.

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: dev-template
    username: ${PERSONALIZATION_USERNAME}   # §05 via personalization.sh
    password: "CHANGE_ME_HASHED"
    realname: "${PERSONALIZATION_FULLNAME}"   # §05
  ssh:
    install-server: true
    allow-pw: false
  packages:
    - curl
    - ca-certificates
    - gnupg
    - git
    - qemu-guest-agent
  late-commands:
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /work && chown ${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME} /work'"
```

Hostname, project volume, and firewall allowlist are set per-clone (§5), not
in the golden image.

## 5. First boot + per-project provisioning (`dev-firstboot.sh`)

Fetched at `<REF>`; logs to `/var/log/dev-firstboot.log`; self-disables.

1. **Docker CE** — install from `download.docker.com` (official upstream only);
   `usermod -aG docker ${PERSONALIZATION_USERNAME}` (§05); harden daemon (`overlay2`, `json-file`
   `10m×3`, `live-restore`); `systemctl enable docker`.
2. **Workspace** — `mkdir -p /work`, `chown ${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME} /work` (§05). Per-project
   volumes mounted by the operator (§5.3), not in the golden image.
3. **Git config** — set global git identity per §05:
   `git config --global user.name "${PERSONALIZATION_FULLNAME}"` and
   `git config --global user.email "${PERSONALIZATION_EMAIL}"`.
4. **Base image pulls** — pull pinned base images in parallel:
   `eclipse-temurin:21-jre-jammy`, `coursier/jre:21`,
   `sbtscala/sbt:1.10.7_2.13.15_3`, `node:20-slim`. Log each SHA.
5. **Install Dockerfiles** — copy `dev/docker/*` to `/opt/dev-docker/` on the
   VM. These are used by wrapper scripts for lazy image builds.
6. **Wrapper scripts** — write four scripts to `/home/${PERSONALIZATION_USERNAME}/.local/bin/`:
   `java`, `scala`, `sbt`, `opencode`. Each checks if its image exists;
   if not, builds it from `/opt/dev-docker/Dockerfile.*` with
   `--build-arg PERSONALIZATION_USERNAME=${USER}`. Then runs the ephemeral
   container (§5.5). `chmod +x`. Add `~/.local/bin` to PATH via `.bashrc` snippet.
7. **Cache directories** — `mkdir -p ~/.sbt ~/.ivy2 ~/.cache/coursier
   ~/.config/opencode`; `chown ${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}` (§05) all. These are bind-mounted
   into containers for build-cache persistence.
8. **Firewall** — `ufw default deny incoming; default deny outgoing; allow ssh`;
   allow out 53,80,443 (DNS, HTTP, HTTPS for image pulls and package repos).
   `echo y | ufw enable`. **Host-level enforcement**: the host's iptables
   OUTPUT chain drops all outbound from dev VMs by default; `ufw` rules inside
   the VM are a secondary defense.
9. **Hostname** — `hostnamectl set-hostname dev-vm`; self-disable
   `systemctl disable --now dev-firstboot`.

### 5.3 Per-project clone contract (operator, not in golden)

```bash
qm clone <dev-golden-vmid> 102 --name dev-alpha --full
qm set 102 --memory 4096 --cores 4 --cpu host
qm set 102 --ciuser ${PERSONALIZATION_USERNAME} --sshkeys ~/.ssh/authorized_keys
# optional per-project data volume:
# qm set 102 --scsi1 local-lvm:50,size=100G  # mounted at /work/alpha
qm start 102
```

Set unique hostname, regenerate `machine-id`/SSH keys via cloud-init,
mount `/work/<project>`, record project→VMID mapping in ops docs.

### 5.5 Ephemeral-container + wrapper-script pattern

All dev tools (Java, Scala, sbt, opencode) run in **ephemeral Docker
containers** with the **current working directory bind-mounted** into the
container at `/work`. The VM itself contains no toolchain — only Docker, git,
and the wrapper scripts.

**General pattern:**

```bash
docker run --rm \
  -v "$(pwd):/work" -w /work \
  [-v <cache-or-config-mounts>] \
  <image> <tool> [args...]
```

Key properties:
- `--rm`: container is destroyed on exit; no state accumulates inside layers.
- `-v "$(pwd):/work" -w /work`: the directory you `cd` into on the host is
  the working directory inside the container. File reads/writes are real-time.
- `[args...]`: all command-line arguments are passed through to the tool
  entrypoint unchanged.
- Cache mounts (`~/.sbt`, `~/.ivy2`, `~/.cache/coursier`) persist across
  container runs for fast incremental builds.
- Config mounts (`~/.config/opencode`) are **read-only** (`:ro`) to prevent
  container-side modifications from drifting host config.

**Wrapper scripts** (`/home/${PERSONALIZATION_USERNAME}/.local/bin/java`, etc.):

Each wrapper checks if its Docker image exists and builds it on first use
from `/opt/dev-docker/Dockerfile.*`:

`java`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-java"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.java" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" java "$@"
```

`scala`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-scala"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.scala" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" scala "$@"
```

`sbt`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-sbt"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.sbt" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.sbt:/home/${USER}/.sbt" \
  -v "${HOME}/.ivy2:/home/${USER}/.ivy2" \
  -v "${HOME}/.cache/coursier:/home/${USER}/.cache/coursier" \
  "$IMAGE" sbt "$@"
```

`opencode`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DOCKER_DIR="/opt/dev-docker"
IMAGE="dev-opencode"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[dev] Building ${IMAGE} (first run)..."
    docker build --tag "$IMAGE" \
        --build-arg PERSONALIZATION_USERNAME="${USER}" \
        -f "${DOCKER_DIR}/Dockerfile.opencode" "$DOCKER_DIR"
fi
exec docker run --rm \
  -v "$(pwd):/work" -w /work \
  -v "${HOME}/.config/opencode:/home/${USER}/.config/opencode:ro" \
  "$IMAGE" opencode "$@"
```

No long-lived mutable containers; no toolchain baked into the VM; state
lives in `/work`, containers are disposable.

## 6. Image build + cleanup

Same discipline as Specs 02/03 §6: throwaway builder, `virt-sysprep`
(host keys, machine-id, logs, history), `zerofree`, output to
`output/dev-golden.qcow2` + SHA256 + `user-data` hash in `output/MANIFEST`,
delivered to `payloads/` for `import-from`/clone (Spec 01 §5.3).

## 7. Acceptance

* Unattended install; boot to console via `serial0`; no GPU devices
  (`lspci | grep -i 'vga\|3d'` empty except virtio).
* `docker run --rm hello-world` succeeds as `${PERSONALIZATION_USERNAME}` (§05); daemon flags verified.
* All four tool images exist: `docker images dev-{java,scala,sbt,opencode}`
  shows correct base tags and entrypoints.
* Wrapper scripts are executable and on PATH: `which java scala sbt opencode`
  each returns `/home/${PERSONALIZATION_USERNAME}/.local/bin/<tool>`.
* Ephemeral container demo: from `/work/<project>`, `java -version` runs in
  `dev-java` container and prints OpenJDK 21; `sbt --version` runs in
  `dev-sbt` container; no state remains after exit.
* Cache persistence: run `sbt compile` twice; second run shows cached
  dependencies (faster).
* Egress-deny holds: `curl` to archive/allowlisted endpoints succeeds,
  arbitrary egress fails; only SSH reachable inbound; PVE `firewall=1` set.
  Host iptables OUTPUT chain is the authoritative enforcement point.
* Per-project clone produces unique hostname/keys/IP; golden has no identity.
* `git config --global user.name` returns `${PERSONALIZATION_FULLNAME}` (§05);
  `git config --global user.email` returns `${PERSONALIZATION_EMAIL}`.
* Rebuild at same REF reproduces (Docker pin + image SHAs recorded in MANIFEST).
