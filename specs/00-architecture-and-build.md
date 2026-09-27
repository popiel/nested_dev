# Spec 00 — Architecture and build overview

Status: Draft
Applies to: Proxmox VE host, desktop guest, LLM guest, dev template, dev project VMs
Pinned versions: Proxmox VE **9.2**, Ubuntu **26.04 LTS**
Implementation: whole of `provision/`, `desktop/`, `llm/`, `dev/`

## 1. Scope

Defines the fleet this repository builds and provisions, the decisions that
apply across all of it, and the requirements every artifact shares.

In scope: component inventory, topology, cross-cutting decisions, artifact
provenance, build ordering, shared acceptance. Out of scope: per-component
detail (Specs 01–09).

### Purpose

A safe environment for running untrusted software. Each concern — desktop,
LLM inference, software development — is isolated in its own guest VM under a
minimal host hypervisor. Guests are rebuilt from trusted sources on a regular
cycle to contain any corruption that occurs.

## 2. Components

| # | Component | Role | Auto-starts |
|---|---|---|---|
| Host | Proxmox VE 9.2 | Minimal hypervisor: KVM, storage, bridging, VM lifecycle. No significant utilities. | — |
| vm 100 | `desktop` | Owns the motherboard iGPU. Display server and bastion for the other guests. | Yes |
| vm 101 | `llm` | Owns the discrete GPU(s). CUDA and LLM inference, containerised. | Yes |
| vm 102 | `dev-template` | Clone source for every per-project dev VM. PVE template. | Never |
| vm 103+ | `dev-<project>` | One software project each. Disk + Docker engine; dev work in ephemeral containers. | Never |
| vm 200–249 | reserved | Future workload guests. | Never |

Additional workload guests can be added without rebuilding the host install
media.

## 3. Topology

```
+-----------------------------------------------------------------------+
|  Host: Proxmox VE 9.2 (minimal, headless)                             |
|                                                                       |
|  $PHYS_NIC (DHCP) --- LAN 192.168.14.0/24                             |
|  vmbr0 (private, 192.168.100.1/24) --- VMs                            |
|  dnsmasq on vmbr0: DHCP + DNS for VMs                                 |
|  NAT/MASQUERADE: VMs -> $PHYS_NIC -> LAN                              |
|  storage: local-lvm thin                                              |
|  RAM: 2 GB reserved for host; rest via balloon + ZRAM + swap          |
|                                                                       |
|  vm 100 desktop <-- iGPU (VFIO)                                       |
|  '-- Ubuntu Desktop 26.04 + i3-gaps/dmenu + xrdp (:3389) + lightdm    |
|      Firefox + Chrome (snap); SSH client; X11 forwarding from dev VMs |
|      192.168.100.100  lychee                                          |
|                                                                       |
|  vm 101 llm     <-- dGPU(s) (VFIO)                                    |
|  '-- Ubuntu Server 26.04 + NVIDIA driver + CUDA + Docker               |
|      + Ollama/vLLM containers; models on /data/models                 |
|      192.168.100.101  lychee-llm                                      |
|                                                                       |
|  vm 102    dev-template (PVE template, clone source)                  |
|  '-- Ubuntu Server 26.04 + Docker engine; never auto-started          |
|      192.168.100.102  lychee-dev-template                             |
|                                                                       |
|  vm 103+   dev-<project> (on demand via devctl, Spec 07)              |
|  '-- Cloned from 102; stopped unless started by the desktop           |
|      192.168.100.103+  lychee-dev-<project>                           |
|      vm 103 = dev-nested (nested_dev repo, Spec 08)                   |
|                                                                       |
|  vm 200..249   reserved                                                |
+-----------------------------------------------------------------------+
```

Physical display outputs on the motherboard belong to vm 100 once the iGPU is
passed through. The host is then framebuffer-less; management is via SSH, the
Proxmox web UI, or a serial/IPMI console.

## 4. Requirements

### R-00.1 Version pinning

* **R-00.1.1** Host is Proxmox VE 9.2. All guests are Ubuntu 26.04 LTS.
* **R-00.1.2** Every third-party input is identified by a version and, where
  the publisher publishes one, a checksum. A base that moves under a
  floating tag is not reproducible.

### R-00.2 Network shape

* **R-00.2.1** The host takes a DHCP lease on the LAN. VMs sit on a private
  `vmbr0` and are **not** addressable from the LAN.
* **R-00.2.2** The host provides DHCP and DNS for `vmbr0`, with a fixed lease
  per VM. Fixed addresses are required because the firewall policy, the host
  trust pin and the SSH config all reference a VM by address.
* **R-00.2.3** VM egress is NAT'd to the LAN. There is no bridged path from a
  VM onto the LAN segment.
* **R-00.2.4** Host management from the LAN is limited to SSH (port 2222) and
  the web UI (port 8006). Host SSH from inside `vmbr0` is accepted from the
  desktop only.
* **R-00.2.5** The host itself reaches only HTTPS, DNS and NTP. A
  hypervisor with unrestricted egress is a hypervisor that can be used as a
  pivot into the LAN it was meant to be shielded from.
* **R-00.2.6** Guest egress is governed by the FORWARD chain, per-guest:

  | Guest | Egress | Rationale |
  |---|---|---|
  | vm 100 desktop | unrestricted | Bastion; browses and fetches |
  | vm 101 llm | 53/80/443 | Installs the driver/CUDA/Docker stack and pulls images and models on first boot |
  | vm 103 `dev-nested` | 53/80/443 | The trusted builder: fetches from GitHub, the Ubuntu archive and the Proxmox ISO mirror |
  | vm 104–249 dev | none | Toolchain is baked into template 102 and cloned already-provisioned, so a clone never needs the network |

* **R-00.2.7** Output-chain restrictions do not constrain guest traffic. A
  rule that governs host-originated packets leaves guest egress untouched, so
  a policy that reads "host OUTPUT is restrictive, therefore guests are
  contained" is wrong.

### R-00.3 Storage

* **R-00.3.1** Guest disks live on `local-lvm` thin provisioning. The host root
  filesystem is `ext4`.
* **R-00.3.2** The LLM VM's model volume is a separate disk mounted at
  `/data/models`, not a directory on the OS disk. Models are the largest
  dataset in the fleet and re-downloading them on a rebuild is unacceptable.
* **R-00.3.3** A per-project dev VM may carry a data volume; it is attached at
  clone time and is not part of the template.

### R-00.4 Memory

| Profile | Host | Desktop | LLM | Dev |
|---|---|---|---|---|
| 32 GB (baseline) | 2 GB hard cap | 8 GB / 4 cores | 16 GB / 6 cores | 8 GB / 4 cores |
| 64 GB+ | 2 GB hard cap | 8 GB / 4 cores | 24 GB / 8 cores | 8 GB / 4 cores |

* **R-00.4.1** The host is hard-capped so a guest cannot starve the hypervisor.
* **R-00.4.2** Guests overcommit via ballooning, ZRAM and disk swap. Total
  guest allocation exceeds physical RAM by design; the host cap is what keeps
  that safe.
* **R-00.4.3** The 16 GB small-host profile is a supported scale-down for the
  LLM VM's memory figure, not a separate topology.

### R-00.5 Guests install from official media; no prebuilt guest images

* **R-00.5.1** There is no golden qcow2, no `payloads/` directory, and no
  image-conversion step. Every guest installs unattended from the official
  Ubuntu ISO with a NoCloud seed (Spec 06).
* **R-00.5.2** Consequently no guest image carries machine-specific identity —
  no SSH host keys, no `machine-id`, no baked IP — and no `virt-sysprep` or
  `zerofree` step exists.
* **R-00.5.3** The dev template is a *running VM converted to a PVE template*,
  not a built artifact. It is the only pre-provisioned state in the fleet, and
  Spec 07 governs its lifecycle.

### R-00.6 GPU and driver delivery

* **R-00.6.1** GPU drivers, CUDA, Docker and serving stacks are installed on
  **first boot** from official upstreams, never baked into a build input. A
  driver baked into a build input ties the input to one driver version and
  forces the build to run on the target GPU hardware.
* **R-00.6.2** The build machine requires no GPU.

### R-00.7 Sourcing policy

* **R-00.7.1** GitHub serves only files authored in this repository: the answer
  file, provisioner scripts and fragments, seed templates, first-boot scripts,
  and network fragments.
* **R-00.7.2** Every third-party artifact is fetched direct from its official
  upstream and is never vendored into this repository: PVE and Ubuntu ISOs,
  Ubuntu archive packages, firmware, the NVIDIA driver and CUDA repositories,
  container images, and any iPXE or firmware payload.
* **R-00.7.3** Vendoring would put third-party code under this repository's
  review and release discipline, and would make its provenance unauditable.

### R-00.8 Pinning and reproducibility

* **R-00.8.1** Every provisioning input is pinned to a single release
  reference, set once in `provision/personalization.sh` (Spec 05 §R-05.8).
* **R-00.8.2** The host install media, the provisioner, and every guest's
  first-boot fetch all use that same reference. A guest that fetches a
  different tree than the host that created it is not reproducible even though
  both report the same ref.
* **R-00.8.3** The resolved commit SHA, plus the versions and checksums of
  third-party inputs, are recorded in a build manifest outside version control.
* **R-00.8.4** Every build script is idempotent. Re-running a build produces
  the same result and does not require cleaning first.
* **R-00.8.5** Built media is never versioned.

### R-00.9 Credential handling

* **R-00.9.1** No real credential is committed. Seeds and templates carry
  placeholder tokens that the build substitutes (Spec 05 §R-05.6).
* **R-00.9.2** The install media is the only carrier of a password hash
  between the build workstation and the host. Hashes never transit a URL.
* **R-00.9.3** The host `root` hash and the operator login hash are separate
  files with disjoint destinations (Spec 05 §R-05.4).

## 5. Build order

1. Edit and push provisioning inputs; set the release reference.
2. Build the host install media against that reference (Spec 01).
3. Provision the host: first-boot provisioner creates vm 100, vm 101 and the
   dev template, converting the template once provisioned (Spec 07).
4. Desktop first boot installs `devctl` and the control keys (Spec 02).
5. `devctl add <project>` creates a dev VM; `devctl start` boots it (Spec 07).
6. Run acceptance tests against the same reference (Spec 09).

Steps 3 and 4 must both complete before step 5: the desktop is the only
component that can create dev VMs.

## 6. Acceptance

Shared by every artifact in this repository.

* **A-00.1** Every artifact installs or boots with no interactive input.
* **A-00.2** Every configuration change traces to a file in this repository.
* **A-00.3** No artifact carries machine-specific identity: no SSH host keys,
  no `machine-id`, no baked IP address.
* **A-00.4** No committed file contains a real credential.
* **A-00.5** Rebuilding from the same reference reproduces the same result,
  within the nondeterminism the manifest documents.
* **A-00.6** Every third-party input is version-pinned and, where the publisher
  supplies one, checksum-verified.
* **A-00.7** `tests/run.sh` exits 0 on a clean checkout (Spec 09).
