# Spec 03 — Guest: LLM VM image (Ubuntu Server 26.04 + CUDA + Docker)

Status: Draft (merged)
Pinned versions: Ubuntu Server **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**

## 1. Purpose and scope

Produce a golden QEMU disk (`llm-golden.qcow2`) for Proxmox **vm 101**. The VM
owns the discrete GPU(s) via VFIO, exposes CUDA to Docker containers, and runs
the LLM serving stack (Ollama baseline, vLLM optional).

In scope: autoinstall `user-data`, first-boot fetch of driver + CUDA + Docker
+ serving baseline from official sources, data-volume contract,
build/cleanup. Out of scope: model catalog, rate limiting, fleet topology,
host wiring (Spec 01 §5.3).

Supersedes `specs-mimo/vm-llm.md` (FAI-baked driver/CUDA/Docker, `/opt/models`
on OS disk, 80 GB) and `specs-ds4/03-guest-llm-image.md` (systemd Ollama,
`/data/models`, 24.04). Merged: ds4's GPU-agnostic image + first-boot-install
discipline with mimo's Docker + Container Toolkit serving model.

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Server **26.04 LTS** (`ubuntu-26.04-live-server-amd64.iso`, SHA256 pinned) |
| GPU driver | NVIDIA proprietary via Ubuntu archive `nvidia-driver-<latest>-server` (datacenter vs consumer chosen at first boot; §5) |
| CUDA toolkit | NVIDIA CUDA repo `cuda-toolkit-<minor>` pinned (e.g. `cuda-13-x` once published for `ubuntu2604`; record exact minor in MANIFEST) — do NOT use Ubuntu `nvidia-cuda-toolkit` |
| Runtime | **Docker CE + NVIDIA Container Toolkit** (mimo model wins over ds4 systemd-Ollama) |
| Serving baseline | **Ollama container** (binds localhost + Desktop-VM peer); optional `vLLM` / `llama.cpp` profiles as containers |
| Data volume | Separate `scsi1` disk from host provisioner, mounted at `/data/models`; `/opt/models` kept as symlink for mimo compat |
| OS disk | **80 GB** virtio (mimo size retained; models live on data volume, not OS disk) |
| Account | `llmuser`, SSH-key-only |
| Identity | No machine-specific data in image |

The image carries **no GPU driver, CUDA, Docker, or Ollama**. All are installed
on **first boot from official upstreams** (Ubuntu archive / NVIDIA /
`download.docker.com` / `ollama.com`), never from this repo (Spec 00 §3
sourcing policy). The build machine needs no GPU; the golden disk stays
GPU-agnostic across driver/toolkit versions.

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-26.04-live-server-amd64.iso` | Official, pinned + SHA256 in `build-iso.sh` |
| `llm/user-data/meta-data` | Empty |
| `llm/user-data/user-data` | Autoinstall (§4) |
| `llm/build-iso.sh` | Injects `autoinstall` param (same routes as Spec 02 §3) |
| `llm/llm-firstboot.sh` | First-boot installer (§5), fetched at `<REF>` |

## 4. `user-data` (representative, 26.04)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: llm-vm
    username: llmuser
    password: "CHANGE_ME_HASHED"   # prefer ssh-only (allow-pw false)
  ssh:
    install-server: true
    allow-pw: false
  packages:
    - pciutils
    - linux-firmware
    - curl
    - ca-certificates
    - gnupg
    - qemu-guest-agent
  late-commands:
    # GPU stack explicitly NOT baked — first boot (§5).
    # /data/models mount (filesystem created by host on first attach if blank):
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /data/models /opt/models && (mkfs.ext4 -F /dev/vdb || true) && echo \"/dev/vdb /data/models ext4 defaults,nofail 0 2\" >> /etc/fstab && mount -a || true && ln -sfn /data/models /opt/models'"
```

Notes:

* `nofail` prevents boot failure when `scsi1` isn't yet attached (image built
  before host attaches the volume). `mkfs` guarded so re-runs don't reformat
  a populated volume — `llm-firstboot.sh` checks for an existing filesystem
  first in production.
* Archive pockets for 26.04 (`resolute`): `main restricted universe
  multiverse` + `-updates` + `-security`.
* Do not bake `nvidia-driver-*`, `cuda*`, `docker-ce`, or Ollama here.

## 5. Serving baseline (first boot, `llm-firstboot.service`)

Seeded like the desktop guest; fetched at `<REF>`; logs to
`/var/log/llm-firstboot.log`; self-disables on success.

1. Install GPU + container stack from **official upstreams only**:
   * Driver: `ubuntu-drivers install` or pinned
     `nvidia-driver-<latest>-server` from the Ubuntu archive; `nvidia-smi`
     must enumerate exactly the passed-through dGPUs.
   * CUDA: add `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/`
     (`cuda-keyring` + pinned `cuda-toolkit-<minor>`); `nvcc --version`
     must match the pin. Record driver + CUDA versions in the log.
   * Docker: official `download.docker.com` repo (`docker-ce`,
     `docker-ce-cli`, `containerd.io`); NVIDIA Container Toolkit from
     `nvidia.github.io/libnvidia-container` (`nvidia-ctk runtime configure
     --runtime=docker`, restart docker); verify
     `docker run --rm --gpus all nvidia/cuda:<pin>-base-ubuntu26.04 nvidia-smi`.
   * Harden daemon (`/etc/docker/daemon.json`):
     `{"storage-driver":"overlay2","log-driver":"json-file",
       "log-opts":{"max-size":"10m","max-file":"3"}}`.
2. Data volume: ensure `/dev/vdb` mounted at `/data/models`, persist fstab,
   `chown llmuser`; keep `/opt/models -> /data/models` symlink.
3. Serving containers (examples; versions pinned in script):
   `ollama/ollama` on `11434` (`-v /data/models/ollama:/root/.ollama`);
   optional `vllm/vllm-openai:latest` on `8000` with
   `--tensor-parallel-size N`; optional `llama.cpp` server on `8080`.
   Bind APIs to localhost + `vmbr0` peer (Desktop/dev VMs); never public.
4. Firewall: `ufw default deny incoming; allow outgoing; allow ssh` only.
   API ports reached via SSH tunnel or peer-VM allow rule, not LAN-wide.
   **Host-level egress**: the LLM VM is restricted to HTTPS (443) only
   by the host's iptables OUTPUT chain. MCP connections to external servers
   use HTTPS; all other outbound is blocked at the host level regardless
   of `ufw` settings inside the VM.

## 6. Image build + cleanup

Identical discipline to Spec 02 §6:

* Throwaway builder VM with no GPU and no driver/CUDA/Docker — all GPU
  components are first-boot actions, image stays GPU-agnostic.
* `virt-sysprep`: SSH host keys, machine-id, logs, history; `zerofree`.
* Record ISO + `user-data` + driver/CUDA/Docker/Ollama pins in
  `output/MANIFEST`; upload `output/llm-golden.qcow2` to `payloads/` for
  `qm ... import-from` (Spec 01 §5.3).

Do not implement mimo FAI `package_config/LLM|DOCKER|GPU-NVIDIA`,
`disk_config/LLM`, `scripts/LLM/*`, or `import-images.sh` — superseded.

## 7. Acceptance

* ISO installs unattended; VM boots to console via `serial0`; `qemu-guest-agent`
  responsive.
* First boot: `nvidia-smi` lists exactly the passed-through dGPUs;
  `nvcc --version` matches pin; `docker run --rm --gpus all ... nvidia-smi`
  succeeds; `torch.cuda.device_count() > 0` (or CUDA sample) passes.
* Ollama: `curl <vm-ip>:11434/api/tags` OK; `ollama run <pinned 8b model>`
  completes with tok/s recorded for the GPU class.
* `/data/models` mounted from `scsi1`, survives reboot; `/opt/models` symlink OK.
* Golden image: no host keys/machine-id/secrets; rebuild at same REF
  reproduces (kernel + driver + CUDA minor pinned).
* Host side: consumer GeForce requires
  `qm set 101 --args '-cpu host,kvm=off,hidden=1'` if applicable (Spec 01 §8).
