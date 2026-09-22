# Spec 03 — Guest: LLM VM image (Ubuntu Server + CUDA)

Status: Draft

## 1. Purpose and scope

Produce a golden QEMU disk (`llm-golden.qcow2`) for Proxmox **vm 101**. The VM
owns the discrete GPU(s) passed through from the host, exposes CUDA to the
service layer, and runs the LLM serving stack.

In scope: autoinstall `user-data`, first-boot fetch of driver + CUDA + serving
baseline from official sources, data volume mount contract, build/cleanup.
Out of scope: model catalog, rate limiting/open-audit, fleet serving topology
(host wiring per Spec 01 §5.2).

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Server 24.04 LTS |
| GPU driver | NVIDIA proprietary via Ubuntu `nvidia-driver-<latest-server>` (or datacenter driver by GPU class) |
| CUDA toolkit | NVIDIA CUDA repository (`cuda-toolkit`, pinned minor, e.g., cuda-12-8) — do NOT mix `nvidia-cuda-toolkit` from Ubuntu |
| Serving baseline | Ollama (systemd, binds `vmbr0` interface); optional `vLLM` profile |
| Data volume | separate `scsi1` disk mounted at `/data/models` (created by host provisioner, Spec 01 §5.2) |
| Identity | no machine-specific data in image |

The image itself carries **no GPU driver, CUDA toolkit, or Ollama**. Those are
installed on **first boot** from their **official upstream sources** (Ubuntu
archive / NVIDIA / ollama.com), not baked into the image and never fetched from
this repo (see Sourcing policy, Spec 00 §3). The image build machine needs no
GPU and no CUDA at all, which keeps the golden disk GPU-agnostic across driver
and toolkit versions. Datacenter vs consumer driver differs only by package
chosen at first boot (Section 5).

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-24.04.2-live-server-amd64.iso` | official, pinned + SHA256 in `build-iso.sh` |
| `user-data/meta-data` | empty |
| `user-data/user-data` | autoinstall (Section 4) |
| `build-iso.sh` | injects `autoinstall` param (same routes as Spec 02 §3) |

## 4. `user-data` (representative)

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
  late-commands:
    # NVIDIA driver, CUDA toolkit, and Ollama are NOT baked here — they are
    # installed on first boot from their official upstream sources (§5).
    # /data/models mount from scsi1 (filesystem set by host on first attach)
    - "curtin in-target --target=/target -- mkfs.ext4 /dev/vdb"
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /data/models && echo \"/dev/vdb /data/models ext4 defaults,nofail 0 2\" >> /etc/fstab && mount -a'"
```

Notes:
- No GPU packages in the image: driver + CUDA + Ollama are fetched by
  `llm-firstboot.service` on first boot (Section 5).
- CUDA pin: choose the minor matching the driver (Sec 7 checks both).
- `nofail` in fstab prevents boot failure if the data volume isn't yet attached
  (image built before host attaches `scsi1`).
- `linux-firmware` ships from the official Ubuntu archive (policy-compliant).

## 5. Serving baseline (first boot, `llm-firstboot.service`)

Seeded the same mechanism as the desktop guest; starts the server that exposes
the model on the `vmbr0` interface IP:

1. Install GPU stack from **official upstream sources only**:
   - NVIDIA driver: `ubuntu-drivers install` (or pin
     `nvidia-driver-<latest>-server`) fetched from the official Ubuntu archive;
   - CUDA: add the NVIDIA repo
     (`developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/`),
     install `cuda-keyring` + pinned `cuda-toolkit-<minor>`;
   - Ollama: `curl -fsSL https://ollama.com/install.sh | sh`.
   Record resolved versions in `/var/log/llm-firstboot.log`. No component is
   fetched from this repo.
2. `nvidia-smi` enumerates N GPUs → writes `/etc/nvidia/...` state JSON for the
   ops layer; asserts GPUs are the passthrough set.
3. Ollama host parameter to bind on the VM's IP, model store on `/data/models`,
   `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL` per policy.
4. Optional profile `vllm`: `pipx`/venv install of `vllm` + serving entry point
   (`vllm serve meta-llama/... --tensor-parallel-size N`) — documented, not
   default.
5. Log to `/var/log/llm-firstboot.log`; unit self-disables.

## 6. Image build + cleanup

Identical discipline to Spec 02 §6:

- Build inside a throwaway VM with no GPU and no driver/CUDA/Ollama installed —
  all GPU components are first-boot actions (§5), so the image itself is
  GPU-agnostic.
- `virt-sysprep`: SSH host keys, machine-id, logs, history, zero-free.
- `zerofree` for the overlarge model partition placeholder — shrink image after
  sysprep.
- Record SHA256 + `user-data` in `output/MANIFEST`; upload to `payloads/`.

## 7. Acceptance

- ISO installs unattended; VM boots to console prompt via `serial0`.
- First boot: `nvidia-smi` lists exactly the passed-through dGPUs; `nvcc
  --version` matches the pin; CUDA samples or `torch.cuda.device_count()>0`.
- Ollama: `curl localhost:11434/api/tags` on the VM IP; `ollama run
  llama3.1:8b --verbose` produces a completion with acceptable tok/s for the
  installed GPU class.
- `/data/models` mounted from `scsi1`; survives reboot.
- Golden image: no host keys/machine-id/plaintext secrets (`grep` audit);
  rebuilding reproduces the same result (pin kernel + driver + CUDA minor in
  `llm-firstboot.sh`).
- Host side (Spec 01 §8 risk table): consumer GeForce in VM requires
  `qm set 101 --args '-cpu host,kvm=off,hidden=1'`; validated therein.