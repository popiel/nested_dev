# Proxmox VE Host Configuration

## Overview

Minimal Proxmox VE 9.2 installation with unattended setup, VFIO GPU
passthrough for three devices (2x GTX 1080 + iGPU), and post-install
configuration pulled from the `popiel/nested_dev` GitHub repo.

## 1. Unattended Installation

### Method: Proxmox Automated Installer with answer.toml

Proxmox VE 9.x uses the `proxmox-auto-install-assistant` tool to prepare
installation ISOs with embedded answer files.

### Step 1: Prepare the ISO

```bash
# Install the assistant on a workstation with the Proxmox ISO
apt install proxmox-auto-install-assistant

# Prepare ISO with embedded answer file
proxmox-auto-install-assistant prepare-iso \
  proxmox-ve_9.2-1.iso \
  --fetch-from iso \
  --answer-file answer.toml

# Output: proxmox-ve_9.2-1-auto-from-iso.iso
```

### Step 2: answer.toml

```toml
[global]
keyboard = "us"
country = "us"
fqdn = "pve.nested-dev.local"
timezone = "UTC"
root-password = "CHANGE_ME_OR_USE_SSH_KEYS"
root-ssh-keys = [
    "ssh-ed25519 AAAA... YOUR_KEY_HERE"
]

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["sda"]

[first-boot]
source = "from-url"
url = "https://raw.githubusercontent.com/popiel/nested_dev/main/scripts/post-install.sh"
ordering = "after-network"
```

### Alternative: preseed-based approach (for older Proxmox or Debian installer)

If using a Debian-installer-based Proxmox ISO, embed a preseed file with
`late_command` to fetch configuration from GitHub:

```preseed
# Fetch and execute post-install configuration
d-i preseed/late_command string \
  in-target wget -O /root/post-install.sh \
    https://raw.githubusercontent.com/popiel/nested_dev/main/scripts/post-install.sh; \
  in-target chmod +x /root/post-install.sh; \
  in-target /root/post-install.sh
```

## 2. Post-Install Configuration

Scripts in `scripts/` on this repo, fetched during or after install.

### 2.1 Package Minimization

Remove non-essential packages from the host:

```bash
#!/bin/bash
# scripts/post-install.sh

set -euo pipefail

# Remove unnecessary packages
apt-get remove -y --purge \
  postfix \
  correlation \
  libcorrelation-common \
  libcorrelation4 \
  librrd8 \
  rrdcached \
  || true

# Hold packages to prevent re-installation
apt-get mark-hold \
  pve-manager \
  pve-kernel-* \
  || true

# Clean up
apt-get autoremove -y --purge
apt-get clean
```

### 2.2 IOMMU / VFIO Configuration

#### Enable IOMMU in GRUB

For Intel CPUs:
```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"

update-grub
```

For AMD CPUs:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"

update-grub
```

#### Load VFIO Modules

```bash
# /etc/modules
vfio
vfio_iommu_type1
vfio_pci
```

```bash
update-initramfs -u -k all
```

#### Blacklist Host GPU Drivers

Prevent Proxmox from claiming the passthrough GPUs:

```bash
# /etc/modprobe.d/blacklist-gpu.conf
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist snd_hda_intel
blacklist i915
blacklist amdgpu
blacklist radeon
```

#### Bind GPUs to vfio-pci

After identifying PCI device IDs with `lspci -nn`:

```bash
# /etc/modprobe.d/vfio.conf
# GTX 1080 #1: vendor:device = 10de:1b80 (VGA), 10de:10f0 (Audio)
# GTX 1080 #2: vendor:device = 10de:1c02 (VGA), 10de:10f1 (Audio)
# iGPU: varies by manufacturer — check with lspci -nn
options vfio-pci ids=10de:1b80,10de:10f0,10de:1c02,10de:10f1 disable_vga=1
```

**Note**: The `ids=` line must include all GPU + audio device pairs.
The iGPU IDs must also be included if it will be passed through to the
Desktop VM. Replace the placeholder IDs with actual values from your
hardware.

#### Verify VFIO Binding (after reboot)

```bash
lspci -nnk -d 10de:
# Should show: Kernel driver in use: vfio-pci

dmesg | grep -i vfio
# Should show devices claimed by vfio-pci
```

### 2.3 Memory Configuration

#### ZRAM for Compressed Swap

```bash
apt-get install -y zram-tools

# /etc/default/zramswap
ALGO=zstd
PERCENT=50
PRIORITY=100
```

```bash
systemctl enable --now zramswap
```

#### Disk Swap

```bash
# Create 4 GB swap file
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
swapon -a
```

### 2.4 Network Configuration

```bash
# /etc/network/interfaces (minimal bridge config)
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

### 2.5 Firewall Rules

```bash
# Allow management access only
# Inbound: SSH (22), Web UI (8006) from management subnet only
# Inter-VM: block by default, allow specific ports as needed

# Proxmox firewall via UI or:
# /etc/pve/firewall/cluster.fw
```

## 3. VM Creation Scripts

After post-install, create VMs using `qm` commands:

### Create LLM VM

```bash
qm create 100 \
  --name llm \
  --memory 10240 \
  --cores 6 \
  --cpu host \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:80 \
  --net0 virtio,bridge=vmbr0 \
  --bios ovmf \
  --machine q35 \
  --vga none \
  --serial0 socket \
  --agent enabled=1

# Attach GTX 1080 #1
qm set 100 --hostpci0 0000:01:00.0,pcie=1,x-vga=1
# Attach GTX 1080 #2
qm set 100 --hostpci1 0000:02:00.0,pcie=1,x-vga=1
```

### Create Desktop VM

```bash
qm create 200 \
  --name desktop \
  --memory 10240 \
  --cores 4 \
  --cpu host \
  --scsihw virtio-scsi-pci \
  --scsi0 local-lvm:30 \
  --net0 virtio,bridge=vmbr0 \
  --bios ovmf \
  --machine q35 \
  --vga none \
  --serial0 socket \
  --agent enabled=1

# Attach iGPU
qm set 200 --hostpci0 0000:00:02.0,pcie=1,x-vga=1
```

## 4. First-Boot Automation

After Proxmox is installed and booted:

1. Fetch and run `scripts/post-install.sh` from GitHub
2. Verify VFIO binding with `lspci -nnk`
3. Import FAI-generated VM images (see `image-generation.md`)
4. Configure cloud-init for each VM
5. Start VMs and verify GPU passthrough

## 5. Rebuild Procedure

The host is designed for regular rebuilds:

1. Boot from prepared Proxmox ISO
2. Automated install runs unattended
3. First-boot script fetches configuration from GitHub
4. VM images imported and configured
5. VMs started

Estimated rebuild time: ~15-20 minutes (SSD, automated).
