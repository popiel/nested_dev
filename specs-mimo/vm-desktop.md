# Desktop VM Specification

## Overview

Ubuntu 26.04 LTS VM with a full desktop environment, passed through
the motherboard's integrated GPU (iGPU) via VFIO for hardware-accelerated
display. Accessed remotely via xrdp (RDP protocol) from any RDP client.

## VM Configuration

| Parameter | Value |
|-----------|-------|
| VM ID | 200 |
| Name | desktop |
| OS | Ubuntu 26.04 LTS (Resolute Raccoon) |
| CPU | 4 cores, host passthrough |
| RAM | 10 GB max (balloon driver enabled) |
| GPU | iGPU via VFIO passthrough |
| Disk | 30 GB (local-lvm, virtio-scsi) |
| Network | virtio NIC on vmbr0 |
| Boot | UEFI (OVMF), q35 machine type |
| Display | iGPU passthrough (physical monitor or xrdp) |
| Agent | QEMU guest agent enabled |

## iGPU Passthrough

### Host-Side Setup

The iGPU must be bound to `vfio-pci` on the Proxmox host (see
`host-proxmox.md`). The iGPU PCI address varies by motherboard:

```bash
# Find iGPU on host
lspci | grep -i 'vga\|display'
# Example: 00:02.0 VGA compatible controller: Intel Corporation ...

# Verify it's bound to vfio-pci
lspci -nnk -s 00:02.0
# Kernel driver in use: vfio-pci
```

### Inside the VM

#### Install GPU Driver

**For Intel iGPU:**
```bash
apt-get update
apt-get install -y intel-media-va-driver-non-free mesa-utils

# Verify GPU access
glxinfo | grep "OpenGL renderer"
# Should show Intel GPU name
```

**For AMD iGPU (APU):**
```bash
apt-get update
apt-get install -y mesa-utils xserver-xorg-video-amdgpu

# Verify
glxinfo | grep "OpenGL renderer"
```

### Display Configuration

The VM boots with the iGPU as its primary display adapter. Since the
VM has no physical monitor attached by default, xrdp provides the
display output over the network.

## Remote Desktop Access (xrdp)

### Install xrdp

```bash
apt-get update
apt-get install -y xrdp xorgxrdp

# Enable and start
systemctl enable --now xrdp

# Add xrdp user to ssl-cert group
adduser xrdp ssl-cert
systemctl restart xrdp
```

### Install Desktop Environment

```bash
# XFCE (lightweight, recommended for limited RAM)
apt-get install -y xfce4 xfce4-goodies

# Or GNOME (full-featured, heavier)
# apt-get install -y ubuntu-desktop

# Or KDE Plasma
# apt-get install -y kde-plasma-desktop
```

### Configure xrdp Session

```bash
# Set default session to XFCE
echo "xfce4-session" > /home/ubuntu/.xsession
chmod +x /home/ubuntu/.xsession

# For GNOME (if using GNOME)
# echo "gnome-session" > /home/ubuntu/.xsession
# chmod +x /home/ubuntu/.xsession
```

### Configure xrdp

```bash
# /etc/xrdp/xrdp.ini
# Ensure port is standard RDP
port=3389

# /etc/xrdp/startwm.sh
# Ensure session startup is correct
# Add at the end of the file:
# test -x /etc/X11/Xsession && exec /etc/X11/Xsession
# exec /bin/sh /etc/X11/Xsession
```

### Firewall

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 3389/tcp    # xrdp
ufw enable
```

## Connection

### From Windows

Use built-in Remote Desktop Connection (`mstsc.exe`):
```
Computer: <VM_IP>:3389
Username: ubuntu
```

### From Linux

```bash
# Using Remmina or xfreerdp
xfreerdp /v:<VM_IP> /u:ubuntu /dynamic-resolution
```

### From macOS

Use Microsoft Remote Desktop or Remmina.

## Desktop Software

Pre-installed via FAI image:

| Category | Packages |
|----------|----------|
| Desktop | xfce4, xfce4-goodies |
| Remote access | xrdp, xorgxrdp |
| Browser | firefox |
| Terminal | xfce4-terminal |
| Editor | mousepad (or code-server) |
| File manager | thunar |
| Dev tools | git, curl, wget, build-essential |
| SSH client | openssh-client |

### Additional Software (install as needed)

```bash
# VS Code
snap install code --classic

# Docker (for development containers)
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu

# Development libraries
apt-get install -y \
  python3-pip \
  nodejs npm \
  golang-go \
  default-jdk
```

## Network Configuration

| Port | Service | Access |
|------|---------|--------|
| 22 | SSH | Management subnet |
| 3389 | xrdp | Management subnet |
| 8080 | Dev servers (optional) | localhost/SSH tunnel |

### Static IP (optional)

```yaml
# cloud-init network config
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      addresses:
        - 192.168.1.200/24
      gateway4: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]
```

## Disk Layout

```
/ (ext4, 30 GB)
├── /home/ubuntu/     # User files and projects
├── /var/lib/docker/  # Docker data (if using dev containers)
└── /opt/             # Additional software
```

## Resource Limits

When both VMs run simultaneously on 16 GB total RAM:

| Metric | Value |
|--------|-------|
| RAM guaranteed | 2 GB (minimum for boot + desktop) |
| RAM maximum | 10 GB (balloon driver) |
| CPU cores | 4 (shared with host scheduler) |
| GPU VRAM | System RAM shared (iGPU uses host RAM) |

### Tuning for Low-Memory Operation

```bash
# Disable unnecessary services
systemctl disable cups || true
systemctl disable avahi-daemon || true
systemctl disable bluetooth || true

# Reduce swap usage
echo 'vm.swappiness=10' >> /etc/sysctl.conf

# Disable compositing in XFCE (reduces GPU memory usage)
xfconf-query -c xfwm4 -p /general/use_compositing -s false
```

## Rebuild Procedure

1. Shut down the VM
2. Delete VM from Proxmox
3. Import fresh FAI-generated disk image (see `image-generation.md`)
4. Apply cloud-init configuration (user, SSH keys, network)
5. Start VM — desktop, xrdp, and iGPU driver are pre-installed
6. Connect via RDP and verify display

## Security Considerations

- xrdp uses TLS encryption for RDP connections
- SSH key-only authentication recommended
- Firewall restricts access to management subnet
- Regular VM rebuilds to contain corruption
- No sensitive data stored on VM — use LLM VM for compute
- xrdp port should not be exposed to public networks

## Troubleshooting

### Black screen after xrdp login

```bash
# Check session log
cat /var/log/xrdp.log
cat /var/log/xorg.log

# Ensure .xsession exists and is executable
ls -la /home/ubuntu/.xsession

# Try manual X session
sudo -u ubuntu startxfce4
```

### GPU not detected inside VM

```bash
# Verify VFIO binding on host
lspci -nnk -s <iGPU_ADDRESS>

# Check dmesg for VFIO errors
dmesg | grep -i vfio

# Ensure iGPU is passed through in Proxmox VM config
qm config 200 | grep hostpci
```

### Poor performance

- Ensure balloon driver is working: `balloonstat` inside VM
- Check for memory pressure: `free -h`, `swapon --show`
- Reduce desktop effects (disable compositing)
- Consider upgrading to 32 GB RAM for better simultaneous operation
