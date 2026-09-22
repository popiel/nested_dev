# Image Generation with FAI

## Overview

All guest VM disk images are built using FAI (Fully Automatic Installation)
on the Proxmox host. FAI creates complete, bootable qcow2 images that are
imported directly into Proxmox as VM templates.

Each VM type (LLM, Desktop) has its own FAI class configuration defining
packages, scripts, and files to install. The FAI config space is stored in
this repository under `fai-config/` and pulled to the Proxmox host during
setup.

## Architecture

```
popiel/nested_dev repo
├── fai-config/              # FAI configuration space
│   ├── class/
│   │   ├── 50-llm           # LLM VM classes
│   │   └── 50-desktop       # Desktop VM classes
│   ├── package_config/
│   │   ├── LLM              # LLM packages
│   │   ├── DESKTOP          # Desktop packages
│   │   └── DOCKER           # Docker packages
│   ├── scripts/
│   │   ├── LLM/             # LLM post-install scripts
│   │   └── DESKTOP/         # Desktop post-install scripts
│   ├── disk_config/
│   │   ├── LLM              # Disk layout for LLM VM
│   │   └── DESKTOP          # Disk layout for Desktop VM
│   └── files/               # Config files to copy into VMs
│
├── scripts/
│   ├── build-images.sh      # Master build script
│   └── import-images.sh     # Import into Proxmox
│
└── specs/                   # This documentation
```

## Prerequisites

FAI must be installed on the Proxmox host (or a build machine):

```bash
apt-get update
apt-get install -y fai-server fai-doc
```

## FAI Configuration Space

### Directory Structure

```
/etc/fai/ (or custom path, e.g., /opt/fai-config/)
├── FAI.conf                 # FAI global configuration
├── nfsroot.conf             # NFS root configuration
├── apt/sources.list         # Package repository sources
│
├── class/                   # Class definitions
│   ├── 50-llm               # LLM VM: defines LLM class
│   ├── 50-desktop           # Desktop VM: defines DESKTOP class
│   └── 50-base              # Common base classes
│
├── package_config/          # Package lists per class
│   ├── BASE                 # Common packages
│   ├── LLM                  # LLM-specific packages
│   ├── DOCKER               # Docker + NVIDIA Container Toolkit
│   ├── DESKTOP              # Desktop environment + xrdp
│   └── GPU-NVIDIA           # NVIDIA driver packages
│
├── scripts/                 # Customization scripts
│   ├── BASE/                # Common setup
│   ├── LLM/                 # LLM-specific setup
│   │   ├── 01-install-nvidia
│   │   ├── 02-install-docker
│   │   └── 03-setup-models
│   └── DESKTOP/             # Desktop-specific setup
│       ├── 01-install-desktop
│       ├── 02-install-xrdp
│       └── 03-configure-session
│
├── disk_config/             # Partition layouts
│   ├── LLM                  # 80 GB disk, ext4
│   └── DESKTOP              # 30 GB disk, ext4
│
└── files/                   # Files to copy into target
    └── etc/
        ├── docker/daemon.json
        └── xrdp/xrdp.ini
```

### Class Definitions

#### `class/50-base` — Common Base

```bash
# Base classes for all VMs
BASE FAIBASE UBUQUO
```

Wait — let me correct this. FAI class files are simple text files
listing one class per line:

```
BASE
FAIBASE
DHCPC
GRUB_EFI
```

#### `class/50-llm` — LLM VM

```
BASE
LLM
DOCKER
GPU-NVIDIA
```

#### `class/50-desktop` — Desktop VM

```
BASE
DESKTOP
XORG
```

### Package Lists

#### `package_config/BASE`

```
PACKAGES aptitude
openssh-server
curl
wget
git
build-essential
sudo
cloud-init
qemu-guest-agent
```

#### `package_config/LLM`

```
PACKAGES aptitude
nvidia-driver-590-server
nvidia-cuda-toolkit
python3-pip
python3-venv
```

#### `package_config/DOCKER`

```
PACKAGES aptitude
docker-ce
docker-ce-cli
containerd.io
```

#### `package_config/DESKTOP`

```
PACKAGES aptitude
xfce4
xfce4-goodies
xrdp
xorgxrdp
firefox
thunar
mousepad
xfce4-terminal
```

### Disk Configurations

#### `disk_config/LLM`

```
# LVM-based layout, 80 GB disk
disk_config {
  disk1 20G ext4
  disk1.1 60G ext4 /
}
```

#### `disk_config/DESKTOP`

```
# Simple layout, 30 GB disk
disk_config {
  disk1 30G ext4 /
}
```

### Customization Scripts

Scripts in `scripts/<CLASS>/` are executed in order during installation.
They use FAI's `fcopy`, `fvar`, and standard shell commands.

#### `scripts/LLM/01-install-nvidia`

```bash
#!/bin/bash
# Install NVIDIA driver (already handled by package list, but
# configure additional settings here)

# Enable persistence mode
cat > /etc/systemd/system/nvidia-persistenced.service << 'EOF'
[Unit]
Description=NVIDIA Persistence Daemon
After=syslog.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --verbose
ExecStopPost=/bin/rm -f /var/lock/nvidia-persistenced.pid
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable nvidia-persistenced
```

#### `scripts/LLM/02-install-docker`

```bash
#!/bin/bash
# Configure Docker for GPU access

# Add Docker to startup
systemctl enable docker

# Configure Docker daemon
fcopy etc/docker/daemon.json /etc/docker/daemon.json

# Add user to docker group
usermod -aG docker ubuntu || true
```

#### `scripts/LLM/03-setup-models`

```bash
#!/bin/bash
# Create directory structure for model storage
mkdir -p /opt/models/{ollama,vllm,huggingface,downloads}
chown -R ubuntu:ubuntu /opt/models
```

#### `scripts/DESKTOP/01-install-desktop`

```bash
#!/bin/bash
# Configure display manager for headless/RDP operation

# Set default target to graphical
systemctl set-default graphical.target || true

# Disable Wayland (xrdp requires X11)
# sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' \
#   /etc/gdm3/custom.conf 2>/dev/null || true
```

#### `scripts/DESKTOP/02-install-xrdp`

```bash
#!/bin/bash
# Configure xrdp

# Add xrdp to ssl-cert group
adduser xrdp ssl-cert || true

# Configure session
echo "xfce4-session" > /home/ubuntu/.xsession
chmod +x /home/ubuntu/.xsession
chown ubuntu:ubuntu /home/ubuntu/.xsession

# Enable xrdp
systemctl enable xrdp
```

#### `scripts/DESKTOP/03-configure-session`

```bash
#!/bin/bash
# Configure XFCE for remote desktop

# Disable compositing (improves xrdp performance)
su - ubuntu -c "xfconf-query -c xfwm4 -p /general/use_compositing -s false" || true

# Set sensible defaults
su - ubuntu -c "xfconf-query -c xfce4-panel -p /panels/panel-1/size -s 32" || true
```

## Building Images

### Master Build Script

```bash
#!/bin/bash
# scripts/build-images.sh
#
# Build all VM disk images using FAI.
# Run on the Proxmox host (or a machine with FAI installed).

set -euo pipefail

REPO_DIR="/opt/nested_dev"  # Where the repo is cloned
FAI_CONFIG="${REPO_DIR}/fai-config"
OUTPUT_DIR="/var/lib/vz/template/iso"  # Where to store images

export FAI_BASEFILEURL="https://fai-project.org/download/basefiles/"
export FAI_DEBOOTSTRAP="https://archive.ubuntu.com/ubuntu"
export NIC1="ens18"

mkdir -p "$OUTPUT_DIR"

echo "=== Building LLM VM image ==="
fai-diskimage \
  -vNu llm-vm \
  -S80G \
  -c "DEBIAN,RESOLUTE64,AMD64,FAIBASE,GRUB_EFI,DHCPC,LLM,DOCKER,GPU-NVIDIA,LAST" \
  -s "file://${FAI_CONFIG}" \
  "${OUTPUT_DIR}/llm-vm.qcow2"

echo "=== Building Desktop VM image ==="
fai-diskimage \
  -vNu desktop-vm \
  -S30G \
  -c "DEBIAN,RESOLUTE64,AMD64,FAIBASE,GRUB_EFI,DHCPC,DESKTOP,XORG,LAST" \
  -s "file://${FAI_CONFIG}" \
  "${OUTPUT_DIR}/desktop-vm.qcow2"

echo "=== Build complete ==="
ls -lh "${OUTPUT_DIR}/"*.qcow2
```

### Import into Proxmox

```bash
#!/bin/bash
# scripts/import-images.sh
#
# Import FAI-built images into Proxmox as VM templates.

set -euo pipefail

STORAGE="local-lvm"
IMAGE_DIR="/var/lib/vz/template/iso"

# Import LLM VM
qm create 9001 \
  --name llm-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0

qm importdisk 9001 "${IMAGE_DIR}/llm-vm.qcow2" "${STORAGE}"
qm set 9001 --scsihw virtio-scsi-pci
qm set 9001 --scsi0 "${STORAGE}:vm-9001-disk-0"
qm set 9001 --boot order=scsi0
qm set 9001 --ide2 "${STORAGE}:cloudinit"
qm set 9001 --bios ovmf
qm set 9001 --machine q35
qm set 9001 --agent enabled=1
qm set 9001 --ciuser ubuntu
qm set 9001 --sshkeys ~/.ssh/authorized_keys
qm template 9001

# Import Desktop VM
qm create 9002 \
  --name desktop-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0

qm importdisk 9002 "${IMAGE_DIR}/desktop-vm.qcow2" "${STORAGE}"
qm set 9002 --scsihw virtio-scsi-pci
qm set 9002 --scsi0 "${STORAGE}:vm-9002-disk-0"
qm set 9002 --boot order=scsi0
qm set 9002 --ide2 "${STORAGE}:cloudinit"
qm set 9002 --bios ovmf
qm set 9002 --machine q35
qm set 9002 --agent enabled=1
qm set 9002 --ciuser ubuntu
qm set 9002 --sshkeys ~/.ssh/authorized_keys
qm template 9002

echo "=== Templates created ==="
qm list | grep template
```

### Deploy VMs from Templates

```bash
# Clone and customize LLM VM
qm clone 9001 100 --name llm --full
qm set 100 --memory 10240 --cores 6
qm set 100 --hostpci0 0000:01:00.0,pcie=1,x-vga=1
qm set 100 --hostpci1 0000:02:00.0,pcie=1,x-vga=1

# Clone and customize Desktop VM
qm clone 9002 200 --name desktop --full
qm set 200 --memory 10240 --cores 4
qm set 200 --hostpci0 0000:00:02.0,pcie=1,x-vga=1
```

## Updating Images

To rebuild images after changing the FAI config:

1. Pull latest repo changes on Proxmox host:
   ```bash
   cd /opt/nested_dev && git pull
   ```

2. Rebuild affected images:
   ```bash
   ./scripts/build-images.sh
   ```

3. Stop affected VMs, delete, and re-import:
   ```bash
   qm stop 100 && qm destroy 100
   ./scripts/import-images.sh
   qm clone 9001 100 --name llm --full
   # Re-apply hardware config
   ```

## Troubleshooting

### FAI build fails with network errors

Ensure the Proxmox host has internet access and the basefile URL is
reachable:

```bash
wget -q --spider https://fai-project.org/download/basefiles/ && echo "OK"
```

### NVIDIA driver installation fails in FAI

The NVIDIA packages require `contrib` and `non-free` repositories.
Ensure `FAI_DEBOOTSTRAP` and the apt sources include these components:

```
deb http://archive.ubuntu.com/ubuntu resolute main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu resolute-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu resolute-security main restricted universe multiverse
```

### Image too large for thin provisioning

If the raw image exceeds storage capacity:

```bash
# Shrink the image before import
qemu-img convert -O qcow2 -o compression_type=zstd \
  input.qcow2 output-small.qcow2
```
