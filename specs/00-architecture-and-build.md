# Spec 00 — Architecture and Build Overview

Status: Draft (merged; supersedes `specs-mimo/` and `specs-ds4/`)
Applies to: Proxmox VE host + Desktop guest + LLM guest + Dev guest(s) media build
Pinned versions: Proxmox VE **9.2**, Ubuntu **26.04 LTS (Resolute Raccoon)**

## 1. Purpose

This directory specifies how to **build and automatically provision** a
virtualization setup from install media, per `README.md`:

1. **Host**: Proxmox VE (headless hypervisor, minimal — KVM, storage,
   bridging, lifecycle only), installed fully unattended from a custom
   autoinstall ISO.
2. **Desktop guest (vm 100)**: Ubuntu Desktop VM that owns the motherboard
   iGPU via VFIO and serves the desktop over RDP (and physical outputs
   where attached).
3. **LLM guest (vm 101)**: Ubuntu Server VM that owns the discrete GPU(s)
   via VFIO and runs CUDA / LLM inference, Docker-based.
4. **Dev template (vm 102)**: Ubuntu Server VM used as the clone source for
   all per-project dev VMs. Created once at host first boot from ISO+NoCloud
   seed, provisioned, then converted to a PVE template (never auto-started).
5. **Dev project VMs (vm 103+)**: cloned on demand from the template via
   `devctl` from the desktop VM. Each hosts one software project. Disk +
   Docker engine only; dev work runs in ephemeral containers. Network
   severely constrained. Created stopped; started/stopped via `devctl`.
6. **Reserved (vm 200–249)**: future workload guests.

No significant utilities run on the host. Additional workload guests can be
added later without touching the ISO.

This spec merges `specs-mimo/` (concrete HOWTO, FAI-based) and `specs-ds4/`
(rigorous autoinstall-based spec). Where they conflicted, this directory wins.
Rationale for each resolution is recorded in §7.

## 2. Target topology

```
+-----------------------------------------------------------------------+
|  Host: Proxmox VE 9.2 (minimal, headless)                             |
|                                                                       |
|  $PHYS_NIC (DHCP) --- LAN 192.168.14.0/24                             |
|  vmbr0 (private, 192.168.100.1/24) --- VMs                            |
|  dnsmasq on vmbr0: DHCP + DNS for VMs                                 |
|  NAT/MASQUERADE: VMs → $PHYS_NIC → LAN                                |
|  storage: local-lvm thin (default); ZFS rpool variant §3              |
|  RAM: 2 GB reserved for host; rest via balloon + ZRAM + swap          |
|                                                                       |
|  vm 100 desktop <-- iGPU (0000:00:02.x, VFIO)   --> hostpci0         |
|  '-- Ubuntu Desktop 26.04 + i3-gaps/dmenu + xrdp (:3389) + lightdm  |
|      Firefox + Chrome (snap); SSH client; X11 forwarding from dev VMs |
|      192.168.100.100 (lychee / lychee.wolfskeep.com)                  |
|                                                                       |
|  vm 101 llm      <-- dGPU(s) (VFIO)          --> hostpci0[,1]        |
|  '-- Ubuntu Server 26.04 + NVIDIA driver + CUDA + Docker             |
|      + Ollama/vLLM containers; models on /data/models                 |
|      192.168.100.101 (lychee-llm / lychee-llm.wolfskeep.com)         |
|                                                                       |
|  vm 102    dev-template (clone source, PVE template)                  |
|  '-- Ubuntu Server 26.04 + Docker engine; never auto-started          |
|      192.168.100.102 (lychee-dev-template)                            |
|                                                                       |
|  vm 103+   dev-<project> (on demand via devctl, Spec 07)              |
|  '-- Cloned from 102; stopped unless started by desktop               |
|      192.168.100.103+ (lychee-dev-<project>)                          |
|      vm 103 = dev-nested (nested_dev repo, Spec 08)                   |
|                                                                       |
|  vm 200..249   (reserved: future workload guests)                     |
+-----------------------------------------------------------------------+
```

Physical display outputs (motherboard HDMI/DP) belong to **vm 100** when the
iGPU is passed through. The host itself is framebuffer-less after boot;
console/management is via SSH, Proxmox web UI, or serial console.

## 3. Decisions and defaults

| Decision | Default | Rationale / alternative |
|---|---|---|
| Host distro | Proxmox VE **9.2** (official ISO, SHA256 pinned in `provision/host/build-iso.sh`) | `specs-mimo` 9.2 wins over `specs-ds4` 8.x; purpose-built KVM, first-class VFIO |
| Guest OS | Ubuntu **26.04 LTS** Desktop (vm 100) / Server (vm 101, 102+) | `specs-mimo` 26.04 wins over `specs-ds4` 24.04 per task instruction; `resolute` archive everywhere |
| VM IDs | `100=desktop`, `101=llm`, `102+=dev-<project>`, `200–249` reserved | `specs-ds4` convention wins; `specs-mimo` (`100=llm`, `200=desktop`, `9001/9002` templates) is superseded |
| Host storage | `ext4` root + `local-lvm` thin for guest disks + 4–8 GB swap (file or partition) | `specs-mimo` simplicity wins; ZFS `rpool` allowed as documented variant in Spec 01, not default |
| Memory model (32 GB host) | Host hard-capped 2 GB; Desktop 8 GB / 4 cores; LLM 16 GB / 6 cores; each Dev 8 GB / 4 cores; QEMU balloon + ZRAM (zstd, 50%) + 4 GB disk swap; 64 GB+ tier: LLM 24 GB / 8 cores | 32 GB is the baseline; 16 GB was the original small-host profile (retained as scale-down path in scripts) |
| Guest media build | `autoinstall` (Subiquity) ISO per guest → host-mediated NoCloud seed at VM creation (Spec 06) | Host fetches user-data from GitHub, injects password hash (+ vmctl key for desktop), builds seed ISO, boots VM with NoCloud seed. No golden qcow2 files. |
| GPU driver delivery | Golden images are **GPU-agnostic**; driver + CUDA + serving stack installed on **first boot from official upstreams** | `specs-ds4` wins; `specs-mimo` baked `nvidia-driver-590-server` into FAI image — rejected (ties image to driver/GPU, needs GPU builder) |
| Desktop session | i3-gaps + dmenu + xrdp + lightdm (default, 32 GB friendly); GNOME + `gnome-remote-desktop` optional profile | i3 is lightweight tiling WM; lightdm for local console on passed-through iGPU; GNOME retained for HW-encode use cases |
| LLM serving | Docker + NVIDIA Container Toolkit; Ollama baseline container, vLLM optional profile; models on separate data volume mounted at `/data/models` (`/opt/models` symlink for compat) | Merge: mimo's Docker model + ds4's separate-volume + first-boot-install discipline |
| Dev model | Docker engine only, ephemeral containers, bind mounts, egress-deny. Template 102 (clone source) created at host first boot, converted to PVE template. Per-project VMs 103+ cloned on demand via `devctl` from desktop, created stopped (Spec 07). | Spec 04 (toolchain) + Spec 07 (lifecycle) + Spec 08 (nested dev) |
| Host networking | Routed: `$PHYS_NIC` DHCP from LAN + private `vmbr0` (192.168.100.1/24); dnsmasq on host serves DHCP/DNS to VMs; host NATs VM egress via MASQUERADE; iptables firewall with per-VM egress policy (desktop=unrestricted, LLM=HTTPS-only, dev=denied, host=HTTPS/DNS/NTP-only) | Replaces bridged design; VMs not directly addressable from LAN; dnsmasq gives predictable IPs without depending on external DHCP |
| Provisioning model | Answer file + provisioner/first-boot scripts fetched from `popiel/nested_dev` GitHub at install/first boot, pinned to `<REF>` (branch/tag/SHA) | `specs-ds4` discipline wins over mimo's `main`-branch fetch |
| **Sourcing policy** | GitHub serves **only files authored in this repo** (answer file, provisioner scripts/fragments, `user-data`, first-boot scripts, network fragments). Every third-party artifact (PVE/Ubuntu ISOs, Ubuntu archive packages, `linux-firmware`, NVIDIA driver/CUDA repo, Ollama, iPXE, firmware) is fetched **direct from its official upstream** — never vendored here | From `specs-ds4` 00 §3, retained verbatim |

## 4. Artifacts produced

| Artifact | Produced from | Consumed by |
|---|---|---|
| `pve_auto.iso` | Official PVE 9.2 ISO + `answer-host.toml` + `keys/password-hash` | Host installer |
| `provision-host.sh` (+ `frag/*.sh`) | `provision/host/` in GitHub at `<REF>` | Host first boot (systemd oneshot) |
| Guest VMs | Ubuntu official ISO + NoCloud seed assembled by host from GitHub-fetched user-data + local password hash (Spec 06) | VMs 100/101/102+ |

## 5. Repository layout (`popiel/nested_dev`, this repo)

Single source of truth for every provisioning input. Built media (ISOs,
golden disks) is never versioned — `provision/host/build-iso.sh` produces
the host ISO into a gitignored `output/`.

```
provision/
  host/
    answer-host.toml           # PVE 9.2 installer answer file (Spec 01 §4)
    build-iso.sh               # host ISO builder (Spec 01 §4)
    provision-host.sh          # first-boot entry point (Spec 01 §5)
    refresh-guests.sh          # operator-run template rebuild (Spec 08 §8.2)
    frag/10-gpu-passthrough.sh # IOMMU + VFIO (Spec 01 §5.1)
    frag/20-memory-swap.sh     # ZRAM + swap, balloon guidance (Spec 01)
    frag/25-desktop-control.sh # vmctl user, keypair, sudoers (Spec 07 §3.1)
    frag/30-create-guests.sh   # NoCloud seeds, qm create 100/101/102 (Spec 06)
    frag/90-finalize.sh        # screening, networking, firewall (Spec 01 §5.3)
    vmctl/
      vmctl-host               # restricted control stub for dev VMs (Spec 07 §3.2)
      sudoers                  # vmctl sudoers drop-in (Spec 07 §3.3)
  network/
    vmbr0-*.conf               # netplan/iptables fragments
    dnsmasq.conf               # DHCP + DNS for VMs on vmbr0
    iptables-forwarding.conf   # firewall rule reference
  personalization.sh           # shared identity (username, UID, repo, ref)
  ubuntu-release.conf          # shared Ubuntu version + URLs
desktop/
  desktop-firstboot.sh        # fetched inside VM 100 on first boot
  devctl                      # desktop-side dev VM control wrapper (Spec 07 §4.1)
  user-data/{meta-data,user-data}
llm/
  llm-firstboot.sh             # fetched inside VM 101 on first boot
  user-data/{meta-data,user-data}
dev/
  dev-firstboot.sh             # fetched inside VM 102+ on first boot
  docker/                      # Dockerfiles for lazy-build toolchain
    Dockerfile.java            # dev-java (Spec 04 §3)
    Dockerfile.scala           # dev-scala (Spec 04 §3)
    Dockerfile.sbt             # dev-sbt (Spec 04 §3)
    Dockerfile.opencode        # dev-opencode (Spec 04 §3)
    Dockerfile.nested          # dev-nested-build (Spec 08 §5)
  tools/
    nested                     # build toolchain wrapper for nested_dev (Spec 08 §6.1)
    dev-refresh-images         # rebuild all tool images (Spec 08 §6.2)
    dev-nested-provision.sh    # one-time nested_dev repo setup (Spec 08 §7)
  user-data/{meta-data,user-data}
specs/                         # this documentation set (merged)
keys/                          # gitignored except *.pub and *.asc
output/                        # gitignored: ISOs, MANIFEST
```

Repo-authored install- and first-boot-time fetches reference the raw base

```
https://raw.githubusercontent.com/popiel/nested_dev/<REF>/<path>
```

`<REF>` is a branch name, git tag, or commit SHA — set via
`PERSONALIZATION_REF` in `provision/personalization.sh`. Branch names
and tags resolve automatically in GitHub raw URLs; the resolved commit
SHA is recorded in `output/MANIFEST` for reproducibility. Each build
script must be idempotent and pinned to download hashes (see individual
specs).

## 6. Build order

1. Edit and push provisioning inputs; set `PERSONALIZATION_REF` to a branch, tag, or SHA.
2. Spec 01 — build and verify the host install media against the pinned REF
   (`proxmox-auto-install-assistant verify` + test boot).
3. Spec 02 — desktop user-data + first-boot scripts (26.04 Desktop, NoCloud seed).
4. Spec 03 — LLM user-data + first-boot scripts (26.04 Server, NoCloud seed).
5. Spec 04 — dev user-data + first-boot scripts (26.04 Server, NoCloud seed, Docker only).
6. Spec 07 — dev fleet lifecycle: vmctl/vmctl scripts, devctl, firewall additions.
7. Spec 08 — nested dev repo VM: Dockerfile.nested, nested wrapper, dev-refresh-images.
8. Provision host (host first boot): host ISO + first-boot provisioner creates
   Desktop (100) and LLM (101) with NoCloud seeds and starts them; creates dev
   template (102) with NoCloud seed, provisions it once, converts to PVE template.
9. Desktop first boot: installs devctl + vmctl key; starts working.
10. First `devctl add nested` creates VM 103; `devctl start 103` provisions it.
11. Run acceptance tests (all against the same pinned REF).

## 7. What was merged / rejected (traceability to predecessors)

* Versions: PVE **9.2** + Ubuntu **26.04** everywhere. `specs-ds4` 8.x / 24.04
  references are superseded; `specs-mimo` `26.04 Resolute` naming retained.
* IDs: ds4 (`100/101/200–249`) retained; mimo (`100=llm`, `200=desktop`,
  `9001/9002` templates) rejected. Migration: rename/recreate, no alias.
* Storage: mimo `local-lvm` default retained; ds4 ZFS kept as Spec 01 variant.
* Memory: 32 GB baseline (LLM 16 GB, Desktop 8 GB, Dev 8 GB); 16 GB profile
  retained as scale-down path; 64 GB+ tier for LLM 24 GB. ZRAM + balloon
  + 4 GB disk swap overcommit.
* Installer: mimo's 9.2 `prepare-iso --fetch-from` flow + ds4's
  `late-commands` provisioner drop + systemd oneshot merged into one Spec 01.
* VFIO: merged — mimo's GRUB + blacklist baseline for the passed-through set
  plus ds4's `softdep`, audio-function pairing, IOMMU-group abort check, and
  GeForce `kvm=off,hidden=1` workaround.
* Image build: ds4 autoinstall + `virt-sysprep` retained; mimo FAI class space
  and `build-images.sh`/`import-images.sh` rejected (do not implement).
* Desktop: i3-gaps + dmenu + xrdp + lightdm (default); XFCE+xrdp retained as
  lightweight alternative; GNOME+grd retained for HW-encode use cases. Chrome
  via snap on first boot; no dev tools in image.
* LLM: mimo Docker/Toolkit/container examples + ds4 first-boot-install and
  `/data/models` volume merged; Ubuntu `nvidia-cuda-toolkit` rejected in favor
  of NVIDIA-repo `cuda-toolkit-<minor>` for `ubuntu2604`.
* Discipline: ds4 REF-pinning, sourcing policy, MANIFEST, per-spec acceptance
  retained; mimo `main`-fetch rejected.
* New: Spec 04 dev VM closes the `README.md` gap neither predecessor covered.

## 8. Shared acceptance criteria

What all artifacts have in common: installs or boots **without interactive
input**, every configuration change is traceable to a file in this repo,
golden images contain no machine-specific identity (SSH host keys,
machine-id, IP addresses), and rebuilding from scratch against the same
`<REF>` reproduces the same result.

Referenced specs each carry their own acceptance section; this doc is the
aggregate.
