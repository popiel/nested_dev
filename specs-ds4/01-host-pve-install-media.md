# Spec 01 — Host: Proxmox VE autoinstall install media

Status: Draft

## 1. Purpose and scope

Build a bootable ISO that, when booted against a target server, performs a
**fully unattended** Proxmox VE installation and then, on first boot, configures
GPU passthrough and creates the Desktop and LLM guests ready for import.

In scope: ISO preparation, answer file, first-boot provisioner design, guest
VM definitions, build/verification procedure.
Out of scope: guest OS image construction (see Specs 02/03), networking VLAN
design, backup/DR policies.

## 2. Assumptions

- Build machine: Linux with network access; `proxmox-auto-install-assistant`
  available (installable from `pve-no-subscription` repo or the PVE ISO's
  `proxmox-auto-install-assistant` binary).
- All provisioning inputs live in the GitHub repo `popiel/nested_dev` and are
  fetched as `https://raw.githubusercontent.com/popiel/nested_dev/<REF>/...`
  during install (answer file) and first boot (provisioner). `<REF>` is pinned
  per release; machines install against a tagged snapshot, never `main`.
- Install-time HTTP must be reachable for the answer fetch;
  `proxmox-auto-install-assistant`'s `--fetch-from` accepts https URLs. For
  air-gapped sites, `--answer-file` embeds the answer instead (see 6.x).
- Target server: Intel or AMD CPU with VT-d/AMD-Vi in firmware; at least one
  iGPU with motherboard display outputs; one or more discrete NVIDIA GPUs;
  storage disk(s) for ZFS.
- The iGPU and each dGPU must be sitting in **separable IOMMU groups** (verify
  against the target hardware before acceptance; see Section 8).

## 3. Build inputs (file manifest)

| File (repo path) | Description |
|---|---|
| HTTPS PVE ISO (downloaded) | Official, unmodified; pin version + SHA256 in `build-iso.sh` |
| `provision/host/answer-host.toml` | Installer answer file (Section 4) |
| `provision/host/provision-host.sh` | First-boot provisioner entry point (Section 5) |
| `provision/host/frag/*.sh` | Provisioner fragments (GPU config, guest creation) |
| `provision/network/*.conf` | netplan/iptables fragments applied by the provisioner |
| `output/` | build products + `MANIFEST` (gitignored) |

## 4. Answer file — `answer-host.toml` (representative)

Replace every `CHANGE_ME` before building. Passwords: installer enforces
strength rules; use a strong generated value or SSH key only (remove
`root_password` if key-only).

```toml
[global]
    keymap = "en"
    fqdn = "pve-host.CHANGE_ME"
    timezone = "UTC"
    mailto = ""
    root_password = "CHANGE_ME_8plus_complex"
    root_ssh_keys = ["CHANGE_ME_ssh_ed25519_admin"]

[network]
    source = "preconfigured"
    [network.interface]
        name = "CHANGE_ME_enpXs0"      # from lspci/dmesg on target
        cidr = "192.168.1.10/24"
        gateway = "192.168.1.1"
        dns = "192.168.1.1"

[storage]
    disks = "all"
    [storage.zfs]
        pool = "rpool"
        ashift = 12
        compress = "zstd"

[packages]
    install = ["pve-qemu-kvm"]

[installation-options]
    edition = "no-subscription"        # supercedes needing a subscription
    boot-mode = "uefi"
    language = "en_US.UTF-8"
    country = "US"

[late-commands]
    "fetch-provisioner" = "sh -c 'cd /target/root && wget -qO nested_dev.tar.gz https://codeload.github.com/popiel/nested_dev/tar.gz/refs/tags/<REF> && tar -xzf nested_dev.tar.gz && mv nested_dev-<REF>/provision/host provision && rm -rf nested_dev.tar.gz nested_dev-<REF> && chmod +x provision/provision-host.sh'"
    "install-firstboot-unit" = "sh -c 'cat > /target/etc/systemd/system/pve-firstboot.service <<EOF
[Unit]
Description=PVE first boot provisioning
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/root/provision/provision-host.sh
[Install]
WantedBy=multi-user.target
EOF
ln -s /etc/systemd/system/pve-firstboot.service /target/etc/systemd/system/multi-user.target.wants/pve-firstboot.service'"
```

Notes on schema:
- `[network.interface]` is the preconfigured-mode single interface; DHCP mode is
  `source = "from-dhcp"`. Multi-NIC or VLAN setups require validated values per
  the installed `proxmox-auto-install-assistant` version — check
  `proxmox-auto-install-assistant verify` before relying on extensions.
- `late-commands` run inside the installer's chroot (`/target/...` paths are the
  installed system); the `fetch-provisioner` command lands the entire
  `provision/host` tree from the tagged REF into `/target/root/provision`. Use
  `wget`/`curl` there since network is up at that point.
- `disks = "all"` selects every disk — restrict to a disk pattern if the server
  has a dedicated OS disk vs. data disks.

## 5. First-boot provisioner — `provision-host.sh` requirements

`/root/provision/provision-host.sh` runs from the systemd oneshot unit seeded by
`late-commands` (scripts fetched from GitHub, REF pinned). Fragments run in this
order; each must be idempotent and log to `/var/log/pve-firstboot.log`. The unit
disables itself on success (`systemctl disable --now pve-firstboot`).

### 5.1 `frag/10-gpu-passthrough.sh` — IOMMU + VFIO

Requirements (R):

- R1. Kernel cmdline in `/etc/default/grub`:
  `GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt vfio-pci.ids=<IGPU:REV>,<AUDIO_FN:REV>,<DGPU0:REV>,<DGPU0_AUDIO:REV>[,<DGPU1:REV>...]"`
  then `update-grub`. Use `amd_iommu=on` on AMD hosts. `vfio-pci.ids` from
  `lspci -nn` for the iGPU, its companion audio function, and each dGPU + audio.
- R2. Pin early binding via `/etc/modprobe.d/vfio.conf`:
  `options vfio-pci ids=<same> assign_ids=0`
  plus `softdep i915 pre: vfio-pci`, `softdep nouveau pre: vfio-pci`,
  `softdep nvidia pre: vfio-pci`; stub `vfio`, `vfio_iommu_type1`,
  `vfio_pci` in `/etc/modules-load.d/vfio.conf`.
- R3. Do **not** blacklist host drivers that are not in the passthrough set
  (e.g., if the host retains any VGA). When the iGPU is passed, expect the host
  to be framebuffer-less; document this.
- R4. Assert IOMMU groups: `ls /sys/bus/pci/devices/<addr>/iommu_group/devices`
  must contain exactly the intended device set, else abort with a clear message
  listing the offending group. Do not silently proceed.

### 5.2 `frag/20-create-guests.sh` — guest definitions

Creates VMs from golden images delivered in `payloads/` (or cloud images):

- **vm 100 desktop**:
  `qm create 100 --name desktop --memory 8192 --cores 4 --vcpus 4 \
   --net0 virtio,bridge=vmbr0 --ostype l26 \
   --hostpci0 0000:00:02.0,pcie=1,x-vga=0 --hostpci1 <AUDIO_FN>,pcie=1 \
   --scsihw virtio-scsi-single --ide0 <storage>:0,import-from=<desktop-golden.qcow2> \
   --boot order=scsi0 --serial0 socket --vga none`
  - iGPU passthrough; `--vga none` + `x-vga=0` keeps host security clean.
  - RDP published: prefer L2 routing so guests are routable on `vmbr0`; for NAT,
    add `qm set 100 --net0 ...,firewall=1` + a passthrough rule (or host
    `iptables` DNAT) mapping `:3389` to guest. The provisioner applies the
    `provision/network/` netplan/iptables fragment from the repo.
- **vm 101 llm**:
  `qm create 101 --name llm --memory 32768 --cores 16 \
   --net0 virtio,bridge=vmbr0 --ostype l26 \
   --hostpci0 0000:01:00.0,pcie=1 --hostpci1 0000:02:00.0,pcie=1 \
   --scsihw virtio-scsi-single \
   --ide0 <storage>:0,import-from=<llm-golden.qcow2> \
   --scsi1 <storage>:200,size=500G   # model/data volume, mounted by guest \
   --boot order=scsi0`
  - Add one `hostpci` device per dGPU (+ each audio function if in group).
- **future workload guests**: convention — IDs 200–249, one vCPU/2 GB RAM base,
  bridged `vmbr0`, disk on a dedicated `data` zvol exposed via `qm`.
  Provisioning hook-downstream scripts document this contract so additions do
  not require touching the ISO.

### 5.3 `frag/90-finalize.sh` — screening

- Remove machine-specific identity from golden images if imported uncloned:
  ephemeral `qm clone`.
- Write `/etc/hosts` and motd summary; disable `pve-enterprise` repo and point
  `no-subscription` (or mirrored hardening per policy).
- `reboot` (or leave to operator). Unit self-disables.

## 6. Build procedure

```bash
REF=$(git -C . describe --tags --exact-match)   # or explicit vX / commit SHA

# 1) validate the answer file against the builder's schema
proxmox-auto-install-assistant verify provision/host/answer-host.toml

# 2) prepare a bootable autoinstall ISO
#    (answer fetched from the tagged REF at install time)
proxmox-auto-install-assistant prepare-iso \
    iso/proxmox-ve_8.4-1.iso \
    --fetch-from=https://raw.githubusercontent.com/popiel/nested_dev/$REF/provision/host/answer-host.toml \
    --rng-source=autorandom
# output: proxmox-ve_8.4-1_auto.iso
```

Variants:
- Offline/embedded: `--answer-file=provision/host/answer-host.toml` (no HTTP
  dependency; used for air-gapped builds).
- PXE: `proxmox-auto-install-assistant extract-dir | build-iso` per the installed
  tool's help; serve the same content over HTTP + iPXE netboot — the answer file
  is fetched from GitHub either way.
- Lock the answer: `--seed-should-lock` (fails closed on resize).

## 7. Verification (acceptance) on target hardware

1. Boot ISO; assert **no interactive prompts** until the reboot.
2. SSH in; check:
   - `cat /proc/cmdline` contains `intel_iommu=on iommu=pt` (or AMD equiv).
   - `lspci -nnk` → passthrough addresses bound to `vfio-pci`; `lsmod |
     grep -w i915` empty.
   - IOMMU group assertions from R4 passed.
3. `qm list` shows 100/101; `qm start 100`, `qm start 101` succeed.
4. From LAN: RDP to the plumbed endpoint connects to the desktop session.
5. In vm 101 guest: `nvidia-smi` lists the discrete GPU count; short inference
   smoke test succeeds (see Spec 03 acceptance).
6. `cat /var/log/pve-firstboot.log` clean; unit disabled.

## 8. Known risks / mitigation

| Risk | Mitigation |
|---|---|
| iGPU shares IOMMU group with host-critical device | Pre-verify groups on target; may require ACS-override patched kernel (PVE has `pve-kernel` ACS toggle) or accepting limited passthrough; reject host otherwise |
| Consumer GeForce driver fails in VM | VM 101: add `args: -cpu host,kvm=off,hidden=1` via `qm set 101 --args ...`; or use datacenter GPUs |
| dGPU audio function omitted → VM fails/black screen | Pass the audio function too (R1/R2 include it); verify group membership |
| Answer schema drift across PVE versions | Pin ISO version in `build-iso.sh`; run `verify` in CI |
| Host loses console when iGPU passed | Expected (headless); keep IPMI/serial as out-of-band console |
| Install-time network to GitHub unavailable | Use `--answer-file` with a vendored copy, or a mirrored `--fetch-from` URL |
| Provisoner REF drifts from installed ISO | Record REF + ISO hash in `output/MANIFEST`; provision against the recorded REF |
| GitHub outage at guest first boot (later steps) | Guests fetch first-boot scripts from codeload with retry; keep fetches small and logged |