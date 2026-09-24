# Spec 01 — Host: Proxmox VE 9.2 autoinstall install media

Status: Draft (merged)
Pinned versions: Proxmox VE **9.2**, Ubuntu guests **26.04 LTS**

## 1. Purpose and scope

Build a bootable ISO that, when booted against a target server, performs a
**fully unattended** Proxmox VE 9.2 installation and then, on first boot,
configures IOMMU/VFIO, memory overcommit, and creates the Desktop (100), LLM
(101), and Dev (102+) guest definitions ready for golden-image import.

In scope: ISO preparation, answer file, first-boot provisioner design, guest
VM definitions, memory/storage/network defaults, build/verification.
Out of scope: guest OS image construction (Specs 02/03/04), VLAN design,
backup/DR policies.

Supersedes: `specs-mimo/host-proxmox.md` (9.2, DHCP/ext4/`main`-fetch) and
`specs-ds4/01-host-pve-install-media.md` (8.x, static/ZFS/REF-pinned). Merged
below: mimo's 9.2 flow + 32 GB memory profile; ds4's REF-pinning, fragment
layout, IOMMU assertions, and guest conventions.

## 2. Assumptions

* Build machine: Linux with network access; `proxmox-auto-install-assistant`
  from the PVE 9.2 ISO/repo (schema drifts across PVE versions — always run
  `verify` from the same 9.2 tool before building).
* All provisioning inputs live in `popiel/nested_dev` and are fetched as
  `https://raw.githubusercontent.com/popiel/nested_dev/<REF>/...` during
  install (answer file) and first boot (provisioner). `<REF>` is a tag/SHA;
  machines install against a tagged snapshot, never `main`.
* Install-time HTTP must be reachable for `--fetch-from https://...`. For
  air-gapped sites, embed with `--answer-file` instead (see §6).
* Target server: x86_64, VT-d/AMD-Vi enabled; iGPU with board outputs; one or
  more discrete NVIDIA GPUs (e.g. 2× GTX 1080); single NIC minimum; 32 GB RAM
  minimum; SSD/NVMe.
* **LAN**: `192.168.14.0/24` (DHCP-provided). Host gets a dynamic address in
  this range via `$PHYS_NIC`. VMs are on a **private subnet**
  `192.168.100.0/24` (dnsmasq on host). VMs are not directly addressable
  from the LAN; only reachable via host port forwarding. Fixed VM addresses
  assigned by dnsmasq static leases: Desktop `192.168.100.100`,
  LLM `192.168.100.101`, Dev `192.168.100.102+`.
* The iGPU and each dGPU (+ companion audio functions) must sit in
  **separable IOMMU groups** (verify before acceptance, §7 R4).

## 3. Build inputs (file manifest)

| File (repo path) | Description |
|---|---|
| Official `proxmox-ve_9.2-1.iso` (downloaded) | Unmodified; pin version + SHA256 in `provision/host/build-iso.sh` |
| `provision/host/answer-host.toml` | Installer answer file (§4), 9.2 schema |
| `provision/host/provision-host.sh` | First-boot entry point (§5) |
| `provision/host/frag/*.sh` | Fragments: GPU, memory, guest creation, finalize |
| `provision/network/*.conf` | `vmbr0`/firewall/dnsmasq fragments applied by provisioner |
| `output/` | Build products + `MANIFEST` (gitignored) |

## 4. Answer file — `answer-host.toml` (representative, PVE 9.2)

Replace every `CHANGE_ME` before building. Prefer SSH-key-only root (omit
`root-password` if key-only).

```toml
[global]
keyboard = "us"
country = "us"
fqdn = "pve-host.CHANGE_ME"
timezone = "UTC"
mailto = ""
root-password = "CHANGE_ME_8plus_complex"
root-ssh-keys = ["CHANGE_ME_ssh_ed25519_admin"]

[network]
source = "from-dhcp"
# Static alternative (preconfigured):
# source = "preconfigured"
# [network.interface]
# name = "CHANGE_ME_enpXs0"
# cidr = "192.168.14.10/24"
# gateway = "192.168.14.1"
# dns = "192.168.14.1"

[disk-setup]
filesystem = "ext4"
disk-list = ["CHANGE_ME_sda"]
# ZFS variant (documented alternative, not default):
# filesystem = "zfs"
# [disk-setup.zfs]
# pool = "rpool"
# ashift = 12
# compress = "zstd"

[first-boot]
source = "from-url"
url = "https://raw.githubusercontent.com/popiel/nested_dev/<REF>/provision/host/provision-host.sh"
ordering = "after-network"

[late-commands]
"fetch-provisioner" = "sh -c 'cd /target/root && wget -qO nested_dev.tar.gz https://codeload.github.com/popiel/nested_dev/tar.gz/refs/tags/<REF> && tar -xzf nested_dev.tar.gz && mv nested_dev-<REF>/provision/host provision && rm -rf nested_dev.tar.gz nested_dev-<REF> && chmod +x provision/provision-host.sh provision/frag/*.sh'"
"install-firstboot-unit" = "sh -c 'cat > /target/etc/systemd/system/pve-firstboot.service <<EOF\n[Unit]\nDescription=PVE first boot provisioning\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=/root/provision/provision-host.sh\n[Install]\nWantedBy=multi-user.target\nEOF\nln -s /etc/systemd/system/pve-firstboot.service /target/etc/systemd/system/multi-user.target.wants/pve-firstboot.service'"
```

Notes:

* `[global]`/`[network]`/`[disk-setup]` follow the mimo 9.2 field names
  (`keyboard`, `disk-list`); `[network.interface]` preconfigured shape and
  `[late-commands]` chroot (`/target/...`) semantics follow ds4. Validate the
  merged file with the 9.2 `verify` subcommand — schema is version-sensitive.
* `disks`/disk-list: restrict to the OS disk pattern if the server has
  separate OS vs data disks; never blindly wipe data disks.
* `first-boot from-url` and the `late-commands` unit are redundant by design:
  the unit is authoritative (full `frag/` tree at pinned REF); the `first-boot`
  URL is a fallback bootstrap. Both must reference the same `<REF>`.

## 5. First-boot provisioner — `provision-host.sh` requirements

Runs from the systemd oneshot unit. Fragments run in order; each idempotent,
logging to `/var/log/pve-firstboot.log`. Unit disables itself on success.

### 5.1 `frag/10-gpu-passthrough.sh` — IOMMU + VFIO

* R1. Kernel cmdline in `/etc/default/grub`:
  `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"` (Intel) or
  `amd_iommu=on` (AMD), then `update-grub`. Collect `vfio-pci.ids=` from
  `lspci -nn` for the iGPU + its audio function and each dGPU + audio
  (e.g. `10de:1b80,10de:10f0,...` — replace with target values).
* R2. Early binding via `/etc/modprobe.d/vfio.conf`:
  `options vfio-pci ids=<same> disable_vga=1` plus
  `softdep i915 pre: vfio-pci`, `softdep nouveau pre: vfio-pci`,
  `softdep nvidia pre: vfio-pci`; list `vfio vfio_iommu_type1 vfio_pci` in
  `/etc/modules-load.d/vfio.conf`; blacklist only the passed-through set
  (`nouveau nvidia i915/amdgpu` entries scoped to passthrough hardware —
  do not blacklist a GPU retained by the host). `update-initramfs -u -k all`.
* R3. Framebuffer expectation: when the iGPU is passed, the host is
  framebuffer-less; keep IPMI/serial as out-of-band console. Document this.
* R4. Assert IOMMU groups before creating guests:
  `ls /sys/bus/pci/devices/<addr>/iommu_group/devices` must contain exactly
  the intended set, else abort with the offending group listed. Do not proceed
  silently. Consumer-GeForce note: plan `qm set 101 --args '-cpu host,kvm=off,hidden=1'`
  if the driver refuses the VM (see §8).

Verify after reboot: `lspci -nnk` shows `vfio-pci` on passthrough addresses;
`dmesg | grep -i vfio` clean.

### 5.2 `frag/20-memory-swap.sh` — 32 GB overcommit (baseline profile)

From `specs-mimo` (absent in ds4):

```bash
apt-get install -y zram-tools
# /etc/default/zramswap: ALGO=zstd, PERCENT=50, PRIORITY=100
systemctl enable --now zramswap
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab && swapon -a
```

Host hard-capped at 2 GB; guests use QEMU ballooning (`balloon: 1`,
`shares` as needed). On 32 GB hosts this fragment is a no-op beyond ZRAM.

### 5.3 `frag/30-create-guests.sh` — guest definitions

Golden `qcow2` paths come from `output/` / `payloads/` (Specs 02–04).
Conventions (ds4 IDs win):

* **vm 100 desktop** (iGPU):
  `qm create 100 --name desktop --memory 8192 --cores 4 --cpu host
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --ostype l26
  --bios ovmf --machine q35 --vga none --serial0 socket --agent enabled=1
  --hostpci0 0000:00:02.0,pcie=1,x-vga=0
  --ide0 local-lvm:0,import-from=<desktop-golden.qcow2> --boot order=scsi0`
  plus audio function as `hostpci1` if in its own group. Runs i3-gaps +
  xrdp + lightdm; Firefox + Chrome (snap); SSH client for bastion role;
  X11 forwarding from dev VMs. RDP `:3389` is DNAT'd from LAN via host.
* **vm 101 llm** (dGPUs):
  `qm create 101 --name llm --memory 10240 --cores 6 --cpu host
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr0 --ostype l26
  --bios ovmf --machine q35 --vga none --serial0 socket --agent enabled=1
  --hostpci0 <DGPU0>,pcie=1 --hostpci1 <DGPU1>,pcie=1
  --ide0 local-lvm:0,import-from=<llm-golden.qcow2>
  --scsi1 local-lvm:200,size=200G --boot order=scsi0`
  (size the data volume per host: 500G default on 32 GB hosts; 64 GB+ hosts
   may increase further; one `hostpci` per dGPU + paired audio function).
* **vm 102+ dev**: `qm create 10X --name dev-<project> --memory 8192 --cores 4
  --net0 virtio,bridge=vmbr0,firewall=1 ... --ide0 ...import-from=<dev-golden.qcow2>`,
  no `hostpci`. Full contract in Spec 04. Reserve 200–249 for future workload
  guests (1 vCPU / 2 GB base, `vmbr0`, `local-lvm`).

Network default (`/etc/network/interfaces` managed by PVE; routed
architecture):

```
auto lo
iface lo inet loopback

auto CHANGE_ME_eno1
iface CHANGE_ME_eno1 inet dhcp

auto vmbr0
iface vmbr0 inet static
    address 192.168.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

dnsmasq on host serves DHCP/DNS on `vmbr0` (192.168.100.0/24).
Host NATs VM egress via MASQUERADE on `$PHYS_NIC`.
PVE firewall: allow 22/8006 from management subnet only; block inter-VM by
default; open documented ports per guest spec.

### 5.4 `frag/90-finalize.sh` — screening and networking

* Disable `pve-enterprise` repo, enable `pve-no-subscription` (or mirror).
* Detect physical NIC (`$PHYS_NIC`); write `/etc/network/interfaces` with
  `$PHYS_NIC` on DHCP and `vmbr0` as private bridge (`192.168.100.1/24`,
  no `bridge-ports`).
* Install and configure `dnsmasq`: static leases for VMs (MAC addresses
  set in `frag/30`), DNS entries (short + FQDN), upstream DNS from host's
  `/run/resolv.conf`. Enable as systemd service.
* Enable IP forwarding (`sysctl net.ipv4.ip_forward=1`, persisted).
* Apply iptables rules:
  - **NAT**: DNAT `LAN:22→desktop:22`, `LAN:3389→desktop:3389`,
    `LAN:2222(192.168.14.*)→host:22`; MASQUERADE `vmbr0→$PHYS_NIC`.
  - **INPUT**: ACCEPT lo, ESTABLISHED, 2222/lan, 8006/lan, icmp; DROP rest.
  - **FORWARD**: Desktop→any ALLOW; LLM/Dev→Desktop SSH ALLOW;
    ESTABLISHED,RELATED ALLOW; DROP rest.
  - **OUTPUT**: ACCEPT lo, ESTABLISHED, 443, 53, 123; DROP rest.
* Configure host DNS (`/etc/resolv.conf` → `127.0.0.1`).
* Write `/etc/hosts` with VM entries (short + FQDN).
* Write `/etc/hosts`/motd summary; record ISO hash + REF in `output/MANIFEST`.
* Self-disable unit (`systemctl disable --now pve-firstboot`); reboot or hand
  to operator.

## 6. Build procedure (PVE 9.2)

```bash
REF=$(git describe --tags --exact-match)  # or explicit vX / SHA
proxmox-auto-install-assistant verify provision/host/answer-host.toml
proxmox-auto-install-assistant prepare-iso \
  iso/proxmox-ve_9.2-1.iso \
  --fetch-from=https://raw.githubusercontent.com/popiel/nested_dev/$REF/provision/host/answer-host.toml \
  --rng-source=autorandom
# output: proxmox-ve_9.2-1_auto.iso
```

Variants: offline `--answer-file=provision/host/answer-host.toml`;
PXE via `extract-dir` + HTTP/iPXE serving the same answer;
`--seed-should-lock` to fail closed on resize. Pin ISO SHA256 in
`provision/host/build-iso.sh`; record REF + hash in `output/MANIFEST`.

## 7. Verification (acceptance) on target hardware

1. Boot ISO; assert **no interactive prompts** until reboot.
2. SSH in: `/proc/cmdline` has `intel_iommu=on iommu=pt` (or AMD equiv);
   `lspci -nnk` shows `vfio-pci` on passthrough set; R4 group checks passed.
3. `free -h` / `zramctl` show ZRAM + swap active (32 GB profile).
4. `qm list` shows 100/101 (+102 template as applicable); `qm start` succeeds.
5. **Network**:
   - `ip addr show vmbr0` shows `192.168.100.1/24`.
   - `systemctl status dnsmasq` active; `dnsmasq --test` clean.
   - `cat /etc/resolv.conf` shows `nameserver 127.0.0.1`.
   - `iptables -t nat -L PREROUTING -n` shows DNAT rules.
   - `iptables -L OUTPUT -n` shows DROP policy with only 443/53/123 allowed.
   - `ssh -p 2222 root@localhost` reaches host (from LAN).
   - From LAN: `ssh root@<host-ip>` reaches desktop VM (DNAT).
   - From LAN: `mstsc <host-ip>:3389` reaches desktop VM (DNAT).
6. RDP `:3389` reaches vm 100 (Spec 02); `nvidia-smi` in vm 101 lists dGPUs
   (Spec 03); dev VM has no GPU and egress-deny holds (Spec 04).
7. `/var/log/pve-firstboot.log` clean; unit disabled.

## 8. Known risks / mitigation

| Risk | Mitigation |
|---|---|
| iGPU shares IOMMU group with host-critical device | Pre-verify; ACS-override `pve-kernel` toggle or accept limited passthrough (virtual display); else reject host |
| Consumer GeForce driver fails in VM | `qm set 101 --args '-cpu host,kvm=off,hidden=1'` |
| dGPU audio function omitted | Always pass audio pair; verify group membership |
| Answer schema drift (8.x vs 9.x) | Pinned 9.2 ISO + `verify` in CI; this spec's field names are 9.2-only |
| Host loses console when iGPU passed | Expected headless; IPMI/serial required |
| GitHub unreachable at install/first boot | `--answer-file` vendored copy / mirrored `--fetch-from`; small logged fetches with retry |
| REF drift between ISO and guests | Single REF for host + all goldens; recorded in MANIFEST |
