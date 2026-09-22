# System Architecture

## Overview

A minimal Proxmox VE hypervisor host running two Ubuntu 26.04 LTS guest VMs,
each with dedicated GPU passthrough via VFIO. All significant utilities run
in guest VMs; the host OS is kept small and is rebuilt from trusted sources
regularly.

```
┌─────────────────────────────────────────────────────────┐
│                    Physical Hardware                     │
│                                                         │
│  CPU: x86_64 with VT-x/VT-d (Intel) or AMD-V/IOMMU    │
│  RAM: 16 GB                                             │
│  GPUs:                                                  │
│    Slot 1: GTX 1080 #1  ──→ VFIO ──→ LLM VM            │
│    Slot 2: GTX 1080 #2  ──→ VFIO ──→ LLM VM            │
│    iGPU:  Intel/AMD     ──→ VFIO ──→ Desktop VM         │
│  Storage: Local SSD/NVMe for Proxmox + VM disks         │
│  Network: Single NIC (bridge for all VMs)                │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────┐
│              Proxmox VE 9.2 (minimal host)               │
│                                                         │
│  RAM: 2 GB reserved                                     │
│  Role: Hypervisor only — no services beyond PVE mgmt     │
│  No GPU drivers loaded (both GTX + iGPU bound to VFIO)  │
│  Swap: configured for overcommit                        │
│  Access: Web UI on mgmt network, SSH                    │
└──────┬──────────────────────────────────────┬───────────┘
       │                                      │
┌──────▼──────────────┐         ┌─────────────▼───────────┐
│      LLM VM         │         │     Desktop VM           │
│   (Ubuntu 26.04)    │         │   (Ubuntu 26.04)         │
│                     │         │                          │
│  RAM: up to 10 GB   │         │  RAM: up to 10 GB        │
│  CPU: 4-6 cores     │         │  CPU: 2-4 cores          │
│  GPU: 2x GTX 1080   │         │  GPU: iGPU (passthrough) │
│  (VFIO passthrough) │         │  (VFIO passthrough)      │
│                     │         │                          │
│  Role:              │         │  Role:                   │
│   - LLM inference   │         │   - Desktop environment   │
│   - Docker workloads│         │   - xrdp remote access    │
│   - Model storage   │         │   - Development GUI       │
│  Access: SSH, API   │         │  Access: xrdp, SSH        │
└─────────────────────┘         └──────────────────────────┘
```

## Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4-core x86_64 with VT-d/IOMMU | 6+ core with good IOMMU group separation |
| RAM | 16 GB | 32 GB (allows both VMs more headroom) |
| Storage | 256 GB SSD | 512 GB+ NVMe |
| GPU #1 | GTX 1080 (any) | GTX 1080 or better |
| GPU #2 | GTX 1080 (any) | GTX 1080 or better |
| iGPU | Intel HD/UHD or AMD APU | Must support VFIO passthrough |
| NIC | 1 GbE | 1 GbE+ (for management access) |

### Critical: IOMMU Group Requirements

For VFIO passthrough to work correctly, the GPUs and iGPU must be in
separate IOMMU groups. This depends on the motherboard chipset and BIOS:

- **Dual GTX 1080s**: Typically in separate groups if installed in
  different PCIe slots connected to different root ports. Verify with
  `for d in /sys/kernel/iommu_groups/*/devices/*; do n=${d#*/iommu_groups/*}; n=${n%%/*}; printf 'IOMMU group %s ' "$n"; lspci -nns "${d##*/}"; done`

- **iGPU**: Must be isolated from other critical devices (USB, SATA).
  If sharing an IOMMU group with essential host devices, consider
  keeping iGPU on host and using virtual display for Desktop VM.

## Memory Layout (16 GB Total)

With both VMs running simultaneously, memory is tight. ZRAM and swap
on the host provide overflow capacity.

| Component | Reservation | Max Allocatable | Notes |
|-----------|-------------|-----------------|-------|
| Proxmox host | 2 GB | 2 GB | Hypervisor, no services |
| LLM VM | — | 10 GB | Bounded by Proxmox, balloon driver |
| Desktop VM | — | 10 GB | Bounded by Proxmox, balloon driver |
| **Total** | 2 GB | 12 GB | Overcommit via swap/ZRAM |

### Memory Strategy

1. **Proxmox host**: Hard-capped at 2 GB. Uses no swap if possible.
2. **VMs**: Use QEMU ballooning so the active VM can expand into
   available memory. Both VMs can run simultaneously but with reduced
   capacity (~5-6 GB each when both are active).
3. **ZRAM**: Enable zram-tools on Proxmox to compress swap in RAM.
   Effective 2-3x compression ratio gives ~8-12 GB usable swap.
4. **Disk swap**: 4-8 GB swap partition on local storage as overflow.
5. **Future**: Add more RAM (32 GB recommended) to eliminate swap pressure.

## Storage Layout

```
Local Storage (NVMe/SSD)
├── Proxmox root (ext4 or ZFS)
│   ├── / (Proxmox OS)
│   ├── /etc/pve/ (cluster config)
│   └── /var/lib/vz/ (ISOs, templates, snippets)
│
├── local-lvm (LVM-Thin)
│   ├── VM disk images (qcow2 or raw)
│   └── Cloud-init drive images
│
└── Swap partition (4-8 GB)
```

### VM Storage

- LLM VM: 80 GB+ (models are large; 7B params ≈ 4 GB in 4-bit quant)
- Desktop VM: 30 GB (standard desktop + applications)
- Both stored on `local-lvm` for thin provisioning

## Networking

```
Physical NIC ──→ vmbr0 (Proxmox bridge)
                    │
                    ├── LLM VM:    virtio NIC → vmbr0 (bridged)
                    └── Desktop VM: virtio NIC → vmbr0 (bridged)
```

- All VMs get bridged networking through `vmbr0`
- Firewall rules on Proxmox restrict VM-to-VM communication
- LLM VM: outbound only (model downloads), inbound SSH
- Desktop VM: outbound only, inbound xrdp (port 3389) + SSH

## Software Sources

| Component | Source | Version |
|-----------|--------|---------|
| Proxmox VE | official ISO (proxmox.com) | 9.2 |
| Ubuntu desktop/server | Ubuntu cloud images or FAI basefiles | 26.04 LTS |
| NVIDIA drivers (in VM) | Ubuntu restricted/nvidia repos | Latest supported |
| Post-install scripts | `github.com/popiel/nested_dev` | main branch |
| FAI config space | `github.com/popiel/nested_dev` | main branch |

## Security Model

- **Host isolation**: Proxmox runs minimal packages; no user services
- **VM isolation**: Each VM is an independent security domain
- **GPU isolation**: VFIO ensures DMA-level isolation for passthrough GPUs
- **Network isolation**: Firewall rules prevent unnecessary VM-to-VM traffic
- **Regular rebuild**: VMs are designed to be rebuilt from trusted sources
  to contain any corruption or compromise
- **No secrets on host**: Credentials stored only in VMs or fetched at build time
