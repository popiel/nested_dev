# Spec 03 — Guest: LLM VM image (Ubuntu Server + CUDA)

Status: Draft

## 1. Purpose and scope

Produce a golden QEMU disk (`llm-golden.qcow2`) for Proxmox **vm 101**. The VM
owns the discrete GPU(s) passed through from the host, exposes CUDA to the
service layer, and runs the LLM serving stack.

In scope: autoinstall `user-data` (driver + CUDA + serving baseline), data
volume mount contract, build/cleanup.
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

The image itself does **not** need GPU drivers if you prefer first-boot install;
we bake them in because the image build VM has a stub GPU only. Baking is
acceptable because the real PCI devices appear after passthrough and driver
state is per-boot (kernel module loads against whichever NVIDIA device is
present). Datacenter vs consumer driver differs only by package chosen.

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
    # Ubuntu-meshed NVIDIA driver for the GPU class baked in build VM:
    - "curtin in-target --target=/target -- sh -c 'apt-get install -y nvidia-driver-550-server && echo needrestart-suspend | tee /etc/needrestart/conf.d/99-auto.conf'"
    # NVIDIA CUDA keyring + toolkit (pinned):
    - "curtin in-target --target=/target -- sh -c 'wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && dpkg -i cuda-keyring_1.1-1_all.deb && apt-get update && apt-get install -y cuda-toolkit-12-8'"
    # baseline server: ollama
    - "curtin in-target --target=/target -- sh -c 'curl -fsSL https://ollama.com/install.sh | sh'"
    # /data/models mount from scsi1 (filesystem set by host on first attach)
    - "curtin in-target --target=/target -- mkfs.ext4 /dev/vdb"
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /data/models && echo \"/dev/vdb /data/models ext4 defaults,nofail 0 2\" >> /etc/fstab && mount -a'"
```

Notes:
- `nvidia-driver-*-server` package name varies by release; bake whatever
  `ubuntu-drivers` resolves for the target class and freeze it in
  `user-data`.
- CUDA pin: choose the minor matching the driver (Sec 7 checks both).
- `nofail` in fstab prevents boot failure if the data volume isn't yet attached
  (image built before host attaches `scsi1`).

## 5. Serving baseline (first boot, `llm-firstboot.service`)

Seeded the same mechanism as the desktop guest; starts the server that exposes
the model on the `vmbr0` interface IP:

1. `nvidia-smi` enumerates N GPUs → writes `/etc/nvidia/...` state JSON for the
   ops layer; asserts GPUs are the passthrough set.
2. Ollama host parameter to bind on the VM's IP, model store on `/data/models`,
   `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL` per policy.
3. Optional profile `vllm`: `pipx`/venv install of `vllm` + serving entry point
   (`vllm serve meta-llama/... --tensor-parallel-size N`) — documented, not
   default.
4. Log to `/var/log/llm-firstboot.log`; unit self-disables.

## 6. Image build + cleanup

Identical discipline to Spec 02 §6:

- Build inside a throwaway VM (no passthrough needed — CUDA libs install
  fine without a GPU present; only `nvidia-smi` requires the device, which is
  why it is a first-boot action, not part of baking).
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
  `user-data`).
- Host side (Spec 01 §8 risk table): consumer GeForce in VM requires
  `qm set 101 --args '-cpu host,kvm=off,hidden=1'`; validated therein.