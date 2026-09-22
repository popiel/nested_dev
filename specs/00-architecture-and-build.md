# Spec 00 — Architecture and Build Overview

Status: Draft
Applies to: Proxmox VE host + Desktop guest + LLM guest media build

## 1. Purpose

This directory specifies how to **build and automatically provision** a
three-machine virtualization setup from install media:

1. **Host**: Proxmox VE (headless hypervisor), installed fully unattended from a
   custom autoinstall ISO.
2. **Desktop guest**: Ubuntu Desktop VM that owns the motherboard iGPU and serves
   the desktop over both the physical display outputs and RDP.
3. **LLM guest**: Ubuntu Server VM that owns the discrete GPU(s) and runs CUDA /
   LLM inference.

No significant utilities run on the host. The host only provides KVM, storage,
bridging, and lifecycle management so additional workload guests can be added
later.

## 2. Target topology

```
+--------------------------------------------------------------+
|  Host: Proxmox VE 8.x (minimal, headless)                    |
|                                                              |
|  vmbr0 (bridge) --- NIC ---- LAN                            |
|  storage: ZFS rpool (guest disks as zvols/vdisks)            |
|                                                              |
|  vm 100 desktop  <-- iGPU (0000:00:02.x, VFIO)   --> hostpci0
|  '-- Ubuntu Desktop + gnome-remote-desktop / xrdp (RDP :3389)
|      RDP exposed via host port forward or routed bridge      |
|                                                              |
|  vm 101 llm      <-- discrete GPU(s) (VFIO)         --> hostpci0,1
|  '-- Ubuntu Server + NVIDIA driver + CUDA + serving stack   |
|                                                              |
|  vm 200..249   (reserved: future workload guests)           |
+--------------------------------------------------------------+
```

Physical display outputs (motherboard HDMI/DP) are driven by the passed-through
iGPU and belong to **vm 100**. The host itself has no framebuffer after boot;
console/management is via SSH, the Proxmox web UI, or the serial console.

## 3. Decisions and defaults

| Decision | Default | Rationale / alternative |
|---|---|---|
| Host distro | Proxmox VE 8.x (current stable at build time) | Purpose-built KVM, first-class VFIO, trivial guest provisioning later |
| VRAM/display split | iGPU -> desktop, dGPU(s) -> LLM | Matches user requirement |
| Desktop RDP server | `gnome-remote-desktop` primary, `xrdp` fallback | grd is native/Wayland/HW-encodable; xrdp covers TM-compat and failures |
| LLM serving stack | Ollama baseline; vLLM optional profile | Simple default; swap by providing a different `late-commands` payload |
| Host networking | NIC bridged to `vmbr0`, VMs on `vmbr0` | Simplest; isolate later with VLANs if required |
| Provisioning model | Answer file fetched at install; post-install `systemd oneshot` provisioner | Keeps ISO generic; allows updating logic without rebuilding media |
| Guest media build | `autoinstall` (Subiquity) ISO per guest | Canonical, repeatable, captures all config in `user-data` |

## 4. Artifacts produced

| Artifact | Produced from | Consumed by |
|---|---|---|
| `pve_auto.iso` | Official PVE ISO + `answer-host.toml` | Host installer |
| `provision-host.sh` (+ fragments) | Repo scripts | Host first boot (fetched from docroot) |
| `desktop-golden.qcow2` (+ `user-data`) | Ubuntu Desktop autoinstall ISO | VM 100 disk |
| `llm-golden.qcow2` (+ `user-data`) | Ubuntu Server autoinstall ISO | VM 101 disk |
| PXE/boot files (`tftp/`, `http/`) | Optional TD variant | Network boot hosts |

## 5. Repository layout (proposed)

```
build/
  host/
    answer-host.toml
    build-iso.sh
    iso/                  (downloaded official PVE ISO; output ISO)
    provision/
      provision-host.sh
      frag/10-gpu-passthrough.sh
      frag/20-create-guests.sh
  desktop/
    build-iso.sh
    user-data/
      meta-data
      user-data
    iso/
    output/ (golden qcow2)
  llm/
    build-iso.sh
    user-data/
      meta-data
      user-data
    iso/
    output/ (golden qcow2)
  docroot/                 (HTTP/PXE docroot merged at deploy time)
specs/                     (this documentation set)
```

Each build script must be idempotent and pinned to download hashes (see
individual specs).

## 6. Build order

1. `specs/01` — build and verify the host install media.
2. `specs/02` — build the desktop guest golden image.
3. `specs/03` — build the LLM guest golden image.
4. Provision host, import golden images, start guests, run acceptance tests.

## 7. Shared acceptance criteria

What all artifacts have in common: installs or boots **without interactive
input**, every configuration change is traceable to a file in this repo, golden
images contain no machine-specific identity (SSH host keys, machine-id, IP
addresses), and rebuilding from scratch reproduces the same result.

Referenced specs must each carry their own acceptance section; this doc is the
aggregate.