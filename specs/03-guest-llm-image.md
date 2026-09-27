# Spec 03 — Guest: LLM serving VM (vm 101)

Status: Draft
Applies to: vm 101 `llm`, hostname `llm-vm`
Pinned versions: Ubuntu Server **26.04 LTS**, Proxmox VE **9.2**
Implementation: `llm/user-data/user-data`, `llm/llm-firstboot.sh`,
`provision/host/frag/30-create-guests.sh`

## 1. Scope

The LLM VM is the fleet's inference host. It owns the discrete GPU(s), exposes
CUDA to containers, and serves models on the private subnet for the desktop and
the dev VMs.

In scope: install seed content, the GPU and container stack, the model data
volume, model-size guidance, the serving baseline, and guest firewall. Out of
scope: host VFIO wiring and IOMMU verification (Spec 01), seed assembly
(Spec 06), which models an operator chooses to pull, dev toolchain images
(Spec 04).

## 2. Decisions

| Aspect | Choice |
|---|---|
| Base | Ubuntu Server 26.04 LTS, official ISO |
| GPU | Discrete NVIDIA card(s) via VFIO; the iGPU stays with the desktop |
| Driver | Ubuntu archive, recommended driver, falling back to a pinned server branch |
| CUDA | NVIDIA's own repository for the guest's release, toolkit only — never the distro's `nvidia-cuda-toolkit` |
| Runtime | Docker CE with the NVIDIA Container Toolkit |
| Serving baseline | One Ollama container on port 11434 |
| GPU visibility to the host | `vga none`; the guest has no emulated display, only the passed-through card |
| Data volume | Second virtio disk, mounted at `/data/models`; `/opt/models` is a symlink to it |
| OS disk | 80 GB |
| Identity | The account from Spec 05; guest `root` locked |
| Console | Serial console, autologin as the account, reachable with `qm terminal` |
| Model policy | Nothing is ever pulled automatically |

### 2.1 Why the driver and toolkit are not in the seed

The driver and the CUDA toolkit are installed on first boot from their official
upstreams. This is a deliberate exception to "the seed is the image": the
guest's own GPU is present only after passthrough, and driver and toolkit
versions track that hardware. A driver chosen when the image was built is a
driver chosen against a guess.

The consequence is accepted: the first boot is long, and a first boot that
fails part-way leaves a guest that is installed but not serving. The log names
what failed.

## 3. Requirements

### R-03.1 Install

* **R-03.1.1** The VM installs unattended from the official Ubuntu Server ISO
  with the host-assembled NoCloud seed (Spec 06). No image is built for it.
* **R-03.1.2** The seed carries the account identity, the operator and
  guest-identity keys, the account's UID and GID, guest `root` locked, and the
  packages needed to reach and verify the hardware: PCI enumeration tools,
  kernel firmware, HTTP and GPG tooling, the guest agent, and version-control
  tooling. It carries **no** driver, no toolkit, and no container runtime.
* **R-03.1.3** The account's UID and GID are set before any ownership
  operation on that account's files.
* **R-03.1.4** SSH password authentication is disabled, so the two injected
  public keys are the only way in.
* **R-03.1.5** A serial console is enabled and autologs the account, and the
  guest is created with a serial console socket rather than a VGA device. The
  VM has no physical display, so the serial console is its only console, and it
  is the way an operator gets in when the first-boot script has failed.

### R-03.2 The GPU stack is installed at first boot and verified per layer

* **R-03.2.1** The NVIDIA driver is installed from the Ubuntu archive, and the
  driver version actually installed is recorded in the log.
* **R-03.2.2** A missing driver is a **fatal** error at this stage, unlike the
  container checks below. Without a driver the rest of the stack is
  meaningless, and the operator needs to know now rather than after a 20-minute
  container install.
* **R-03.2.3** The CUDA toolkit is installed from NVIDIA's own repository for
  the guest's release, at a pinned minor version, with a documented fallback to
  an earlier pinned minor when the newest is not yet published for the release.
  The installed version is recorded in the log. The distro's toolkit package is
  not used: it pins a different driver branch than the one the guest has.
* **R-03.2.4** The toolkit's `bin` and `lib64` directories are on the login
  environment's `PATH` and library path, so `nvcc` is usable from a shell
  without further setup.
* **R-03.2.5** Docker CE is installed from Docker's own repository after any
  conflicting distribution container packages are removed. Its daemon log
  rotation is bounded, and its storage driver is set explicitly. An unbounded
  JSON log on a long-lived inference host eventually fills the filesystem that
  holds the models.
* **R-03.2.6** The NVIDIA Container Toolkit is installed from NVIDIA's
  repository, registered as a Docker runtime, and the daemon restarted.
* **R-03.2.7** GPU access is verified **from inside a container**, not only on
  the host. Host-level `nvidia-smi` succeeding while containers see no GPU is
  the failure this check exists to catch.
* **R-03.2.8** A failed container-runtime or toolkit check is reported as a
  warning, not a failure. The guest is still a working SSH host and still has
  its model volume; refusing to finish leaves no way to diagnose.

### R-03.3 The model data volume

* **R-03.3.1** Model data lives on its own disk, not on the OS disk. The OS
  disk is reinstalled when the base release changes; the models are not.
* **R-03.3.2** The volume is formatted only when it has no existing
  filesystem, and mounted only when it is not already mounted. Re-running first
  boot must not reformat a volume full of models.
* **R-03.3.3** The mount is persisted with a `nofail` option, so a volume that
  is detached — or a VM cloned before its volume exists — still boots to a
  working login.
* **R-03.3.4** An absent volume is a warning. The guest installs and runs
  without it; models are then unavailable and the operator attaches a volume and
  re-runs.
* **R-03.3.5** `/opt/models` resolves to the data volume, so both path
  spellings refer to one set of models. Two paths with two filesystems is a
  way to fill the OS disk with models by accident.
* **R-03.3.6** The volume is owned by the account, so models written by the
  serving container are readable and removable by the operator without `root`.

### R-03.4 Model guidance is printed, never acted on

* **R-03.4.1** First boot reports each GPU's VRAM and the total, and prints
  recommendations matched to the detected total, to the console and the log.
* **R-03.4.2** The printed guidance covers the two-card case, the single-card
  case, and the case where no usable GPU is present.
* **R-03.4.3** **No model is ever pulled automatically.** An unattended first
  boot has no way to know which models the operator wants, and a wrong guess
  spends gigabytes of a volume the operator may be budgeting.
* **R-03.4.4** When no usable GPU is detected, the guidance says so explicitly
  and points at the host, rather than reporting a VRAM total of zero and
  printing an ordinary table. The likely cause is passthrough, which is a host
  problem.
* **R-03.4.5** The inference service still starts without a GPU. A
  machine-specific fault in the host's passthrough should not take the guest
  offline.

### R-03.5 The serving baseline

* **R-03.5.1** One Ollama container runs, is configured to start again after a
  reboot, and is created with GPU access and its model store on the data
  volume.
* **R-03.5.2** The API is published on the private subnet, not on all
  interfaces. Publishing on all interfaces would put an unauthenticated
  inference API on the LAN regardless of the host's forwarding rules.
* **R-03.5.3** The container's port is reachable on the private subnet once
  first boot completes, and first boot reports whether it is answering.
* **R-03.5.4** An existing Ollama container is started rather than replaced,
  so a re-run does not discard a container the operator has configured.
* **R-03.5.5** The guest itself holds no baked Ollama service and no systemd
  unit for one. The container is the only serving path, so there is one thing
  that serves models.

### R-03.6 Guest firewall

* **R-03.6.1** Incoming traffic is denied by default; SSH and the inference
  port from the private subnet are accepted.
* **R-03.6.2** The inference port is not accepted from the LAN. The host's
  forwarding chain does not route there for this guest either
  (Spec 00 §R-00.2.6).
* **R-03.6.3** Outgoing traffic is unrestricted by the guest firewall; the
  host's forwarding chain is the authority for this guest's egress.
* **R-03.6.4** Guest `root` is locked.

### R-03.7 Sizing

* **R-03.7.1** The VM receives 16 GB and 6 cores on a 32 GB host, and 24 GB and
  8 cores on a 64 GB or larger host. The remaining memory is the host's own
  2 GB cap plus GPU passthrough working space.
* **R-03.7.2** The OS disk is 80 GB and the model volume is 500 GB.

## 4. Invariants

* I-03.1 No driver, toolkit, container runtime or model is present in the seed.
* I-03.2 No prebuilt LLM image exists.
* I-03.3 No model is ever pulled without an operator asking for it.
* I-03.4 The inference API is never published beyond the private subnet.
* I-03.5 Model data is never written to the OS disk.
* I-03.6 Re-running first boot never reformats the model volume.

## 5. Acceptance

| # | Check |
|---|---|
| A-03.1 | The VM installs unattended and reaches a working login on the serial console with no prompts. |
| A-03.2 | The account exists with the configured UID, GID, home and shell; guest `root` is locked; SSH password authentication is refused. |
| A-03.3 | Each passed-through dGPU appears with the NVIDIA driver bound, and the host's iGPU does not appear in this guest. |
| A-03.4 | The log records the driver version and the toolkit release actually installed. |
| A-03.5 | A newer shell finds `nvcc` on `PATH` with no further setup. |
| A-03.6 | The container runtime is responsive, and a container launched with GPU access enumerates the GPU. Withholding the toolkit reproduces a warning, not a boot failure. |
| A-03.7 | The model volume is formatted once, mounted, and survives a reboot. Re-running first boot does not reformat it. |
| A-03.8 | The model volume is present and owned by the account; a symlink resolves the legacy path to the same directory. |
| A-03.9 | With the volume detached, the VM still boots to a working login and the log reports the absence. |
| A-03.10 | Withholding passthrough produces the no-GPU guidance, a total of zero VRAM, and a warning naming the host as the place to check. |
| A-03.11 | The printed guidance matches the detected VRAM in all three cases. The model store is empty after first boot. |
| A-03.12 | The inference API answers from the desktop and from a dev VM, and does not answer from the LAN. |
| A-03.13 | The container starts again after a guest reboot without operator action. |
| A-03.14 | The guest firewall denies unsolicited inbound, accepts SSH and the inference port from the private subnet, and refuses the inference port from the LAN. |
| A-03.15 | On a 32 GB host the VM has 16 GB and 6 cores; on a 64 GB host, 24 GB and 8 cores. |
| A-03.16 | The guest's only console is its serial console; no emulated display device is present. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Topology, memory profiles, egress policy, sourcing and pinning |
| Spec 01 | dGPU passthrough, the GeForce CPU-model override, guest creation |
| Spec 05 | Account identity, UID/GID, locked root, key injection |
| Spec 06 | Seed assembly, placeholder injection, stateful-disk contract |
| Spec 04 | Dev VMs as inference clients |
| Spec 07 | Desktop-side access to the inference API |
| Spec 09 | Seed and first-boot static checks |

## 7. Risks

| Risk | Mitigation |
|---|---|
| Consumer GeForce cards refuse to initialise in a guest | A CPU-model override is applied automatically when a dGPU is present (R-01.6.8) |
| Driver or toolkit unavailable for a new Ubuntu release | Pinned fallbacks and a warning rather than a hard failure; the release reference pins the working combination |
| An unauthenticated inference API reachable from the LAN | The API is published on the private subnet only, and the guest firewall refuses it from the LAN (R-03.6.2) |
| An unattended first boot downloads tens of gigabytes | Nothing is pulled automatically (R-03.4.3); only the stack is installed |
| A re-run reformats the model volume | Formatting is conditional on the absence of a filesystem (R-03.3.2) |
| Models silently fill the OS disk | One path for model data, on a separate disk (R-03.3.5) |
