# Spec 01 — Host: Proxmox VE 9.2 install media and first-boot provisioner

Status: Draft
Applies to: The bare-metal hypervisor host
Pinned versions: Proxmox VE **9.2**, Ubuntu guests **26.04 LTS**
Implementation: `provision/host/build-iso.sh`, `provision/host/answer-host.toml`,
`provision/host/first-boot.sh`, `provision/host/provision-host.sh`,
`provision/host/frag/`, `provision/network/`

## 1. Scope

Builds a bootable ISO that performs a fully unattended Proxmox VE 9.2
installation, then configures the host on first boot: GPU passthrough, memory
overcommit, network and firewall, guest control credentials, and the three
starting guest VMs.

In scope: install media, answer file, first-boot bootstrap, the provisioner
fragment sequence, host network and firewall policy, memory overcommit, build
and verification. Out of scope: guest OS content (Specs 02/03/04), how the
login hash and seeds reach a guest (Spec 06), dev VM lifecycle (Spec 07), VLAN
design, backup and DR policy.

### Preconditions

* Build host: Linux with network access, and the
  `proxmox-auto-install-assistant` tool from the 9.2 ISO or repository.
* Target server: x86_64 with VT-d or AMD-Vi enabled; an iGPU with board
  outputs; one or more discrete NVIDIA GPUs; at least one NIC; 32 GB RAM; SSD
  or NVMe.
* LAN `192.168.14.0/24`, DHCP-provided. Private VM subnet `192.168.100.0/24`.
* The iGPU and each dGPU, together with its companion audio function, sit in
  **separable IOMMU groups**. Verified at install time by R-01.7.

## 2. Requirements

### R-01.1 The installation requires no operator interaction

* **R-01.1.1** Booting the ISO on a conforming target installs the host with
  no prompts: no keyboard layout, no disk selection, no password entry, no
  network configuration. An unattended host that stops for one question makes
  the whole fleet's provisioning unattended only in the parts that run before
  the question.
* **R-01.1.2** The answer file is validated by the 9.2 assistant before the ISO
  is produced. The tool from the pinned 9.2 release is the authority on schema;
  the schema is version-sensitive and field names differ between releases.
* **R-01.1.3** The official PVE ISO is used unmodified, with its checksum
  pinned in the build script.

### R-01.2 The answer file expresses only what the schema supports

The valid top-level sections are `global`, `network`, `disk-setup`,
`post-installation-webhook` and `first-boot`.

* **R-01.2.1** The answer file contains **no `late-commands` section.** PVE's
  autoinstall schema has no such section; a file carrying one fails validation
  with an unknown-field error and the install does not start.
* **R-01.2.2** `global` carries the root password hash and root SSH keys and
  **no non-root user**. There is no identity or users block, so the operator
  account cannot be declared here and is created after installation
  (R-01.3).
* **R-01.2.3** Exactly one of the plaintext or hashed root password fields is
  present, never both.
* **R-01.2.4** The keyboard field takes an XKB layout name, not a country
  code.
* **R-01.2.5** `first-boot` carries the executable and the ordering. Ordering
  is `network-online` or later, because the bootstrap fetches the provision
  tree from the network and a hook that runs before networking is usable fails
  the install.
* **R-01.2.6** `first-boot.source` is `from-iso`, never `from-url`. The
  bootstrap carries the operator login hash; a URL would transit that hash
  through a proxy log, a cache or a shell history.

### R-01.3 The operator account is created before anything can fail

* **R-01.3.1** The first-boot bootstrap creates the operator account defined by
  Spec 05 §R-05.3, and grants it `sudo`.
* **R-01.3.1a** **After provisioning, the operator can administer the host.**
  That means the account exists, belongs to the `sudo` group, logs in with the
  rendered SSH key, and the `sudo` binary is installed. On a host without a
  subscription the enterprise repository answers 401, so the package cannot be
  installed before the repository is repaired — and the repair lives in the
  provision tree, which the bootstrap cannot reach before fetching it. The
  bootstrap therefore creates the *group* (which needs no package manager) and
  the tree installs the *package*.
* **R-01.3.1b** **Provisioning completes on a host whose enterprise repositories
  answer 401.** No package operation may run against the enterprise repository
  before it is disabled; the first one to do so aborts the run, which is how a
  repository problem previously presented as a memory/swap failure with no
  guests. Keeping every package operation inside the fetched tree (rather than
  in the ISO-embedded bootstrap) is what makes a repository fix deployable by
  pushing a commit instead of rebuilding and re-burning installer media.
* **R-01.3.1c** **A host whose provisioning failed is still administrable.**
  The answer file installs the operator's own SSH key on `root`
  (`root-ssh-keys`, Spec 05 §R-05.3), so the operator logs in as `root` with
  the same key they use everywhere else. Root is the *easiest* login on a box
  where provisioning failed, not an inaccessible last resort.
* **R-01.3.2** The bootstrap **fetches the provision tree last.** Account
  creation, hash persistence and key installation all complete before the
  first network fetch is attempted.
* **R-01.3.3** A failed or unreachable fetch therefore leaves a host with a
  working operator login. Without this ordering, an outage during provisioning
  produces a host whose only usable account is `root`.
* **R-01.3.4** Account creation is idempotent and refuses to shadow an
  existing UID or GID belonging to another account (Spec 05 §R-05.3.3).

### R-01.4 The install target disk is pinned, never probed

* **R-01.4.1** The target disk is declared explicitly in
  `provision/personalization.sh` and consumed verbatim. The build performs
  **no target-disk detection.**
* **R-01.4.2** Exactly one disk is named. The schema permits one disk for
  `ext4` and `xfs` and rejects more, so a list cannot express a preference
  order. Multi-disk entries are only meaningful for a pool filesystem, where
  every listed disk joins one pool — a storage design decision, not a
  fallback.
* **R-01.4.3** Because only the intended disk is named and nothing else is
  listed, the installer has no other candidate and **cannot fall back to and
  wipe a data or rotating disk.** This is the property that makes the pinning
  safe, and it is the reason a probe is not merely unnecessary but dangerous:
  a probe run on the build host reports the build host's disks.
* **R-01.4.4** If the named disk is absent, the install stops. A device-name
  mismatch fails the build's target rather than silently installing
  somewhere else.
* **R-01.4.5** The build **rejects** a target disk value that is a `/dev/`
  path, a partition name rather than a whole device, an unquoted or empty
  entry, or a list of more than one disk — before the multi-gigabyte ISO step,
  where the failure would otherwise surface as an opaque schema error or at
  install time.
* **R-01.4.6** Device names are hardware-specific. The target device list is
  confirmable on the target machine before installation.
* **R-01.4.7** Storage-device filtering by serial or model is not used. It
  cannot express an ordering, it does not fail cleanly when nothing matches,
  and matching every non-rotational disk brings data SSDs into scope.

### R-01.5 First-boot provisioning runs as a single ordered, idempotent unit

* **R-01.5.1** A systemd oneshot unit runs the provisioner. It logs to
  `/var/log/pve-firstboot.log` and **disables itself on success.**
* **R-01.5.2** Fragments run in a fixed order, because later fragments depend
  on state earlier ones create:

  | Order | Fragment | Establishes |
  |---|---|---|
  | 1 | `10-gpu-passthrough` | IOMMU, `vfio-pci` binding, the R-01.7 assertion |
  | 2 | `20-memory-swap` | ZRAM, swap, ballooning |
  | 3 | `25-desktop-control` | `vmctl` account, control keypair, guest-identity keypair, inventory, host trust pin |
  | 4 | `30-create-guests` | Seed assembly, guest VMs 100/101, the template conversion gate |
  | 5 | `90-finalize` | Repositories, NIC, `vmbr0`, dnsmasq, forwarding, firewall, manifest |

* **R-01.5.3** Every fragment is idempotent. A re-run after a partial failure
  resumes rather than restarting or corrupting.
* **R-01.5.4** The unit's own full run at the pinned reference is
  authoritative; the ISO-embedded bootstrap exists only to create the account,
  persist the hash, fetch the tree and invoke it. Both reference the same
  release reference.
* **R-01.5.5** The unit remains installed and re-runnable. An operator who
  needs to repair a fragment runs the tree again at the same reference.

### R-01.6 GPU passthrough is bound to the host before any guest is created

* **R-01.6.1** IOMMU is enabled at boot, and the `vfio-pci` driver binds the
  passthrough set — the iGPU, each dGPU, and each companion audio function.
* **R-01.6.2** The set is derived from the machine, not hardcoded to one
  board: an Intel and an AMD iGPU are both handled, and vendor IDs are
  collected from PCI enumeration.
* **R-01.6.3** Only devices in the passthrough set have their host driver
  withheld. A GPU the host retains must keep working; blacklisting by module
  name alone would take it out along with the passed-through one.
* **R-01.6.4** The initramfs is regenerated so the binding survives a reboot
  into the real root filesystem. Without this the host binds correctly on the
  installer and reverts on first boot — the failure appears only after the
  fleet has been created.
* **R-01.6.5** A GPU's companion audio function is passed through with it
  whenever the two sit in the same IOMMU group; omitting it yields a guest
  with no audio device for a display the operator expects to make sound on.
* **R-01.6.6** A virtio GPU is never a passthrough candidate. It is the
  host's fallback console and belongs to the host.
* **R-01.6.7** The host is framebuffer-less once the iGPU is passed through.
  A serial or IPMI console is required and is the documented recovery path.
* **R-01.6.8** Consumer GeForce parts may refuse to run in a guest with
  hardware virtualisation exposed. A documented CPU-model override exists for
  that case (Spec 03 covers guest-side verification).

### R-01.7 Only IOMMU-safe devices reach a guest

* **R-01.7.1** A device is passed through only when its IOMMU group contains
  nothing else, or nothing else besides its companion audio function. Anything
  else in the group would follow the device into the guest.
* **R-01.7.2** A device that fails that rule is **left to the host and named in
  the log with its group and the members that disqualified it** — not attached,
  and not attached quietly. One unsafe device does not disqualify the others.
* **R-01.7.3** When no candidate passes, the run **aborts before binding
  anything to vfio**, naming every candidate and its group. A host where
  nothing can be passed through is told so rather than configured with an
  empty passthrough set.
* **R-01.7.4** Guests attach **exactly the accepted set**: the IOMMU fragment
  publishes which devices passed, and guest creation reads that set rather
  than re-detecting hardware. A device the rule rejected is never attached,
  even when it is physically present, and a missing or empty set aborts guest
  creation instead of creating guests with silently absent hardware.
* **R-01.7.5** A device with no IOMMU group at all is not passed through. IOMMU
  being off in the running kernel is not a passing result.

### R-01.8 The host overcommits memory safely

* **R-01.8.1** The host is hard-capped at 2 GB, so guest allocation cannot
  starve the hypervisor.
* **R-01.8.2** Compressed RAM (ZRAM) and disk swap are configured and enabled,
  and guests have ballooning enabled.
* **R-01.8.3** Overcommit is not applied to a host at or below the baseline
  memory profile, where the guest allocation already fits.

### R-01.9 The host provides DNS and DHCP for the private subnet

* **R-01.9.1** dnsmasq serves DHCP and DNS on `vmbr0`, enabled at boot and
  passing its own configuration test.
* **R-01.9.2** Every VM has a fixed lease and a DNS entry in both short and
  fully-qualified form.
* **R-01.9.3** Upstream DNS is taken from the host's resolver at provision
  time, and the host then resolves through dnsmasq. Guests never depend on the
  LAN's resolver being reachable or correct.
* **R-01.9.4** The LAN-facing NIC is detected rather than assumed, and the
  host network configuration is written from that detection.
* **R-01.9.5** IP forwarding is enabled and persisted.
* **R-01.9.6** `vmbr0` has no physical port. A bridge that includes the LAN
  NIC would place every VM directly on the LAN segment, which R-00.2.3
  forbids.
* **R-01.9.7** The build manifest records the install media's checksum and the
  resolved release reference.

### R-01.10 The host firewall is deny-by-default and per-guest

* **R-01.10.1** All three filter chains default to DROP, and the ruleset is
  persisted so it survives a reboot.
* **R-01.10.2** The policy is:

  | Direction | Policy |
  |---|---|
  | Host INPUT | loopback, established, SSH 2222 from LAN, SSH 22 from the desktop only, web UI 8006 from LAN, ICMP echo. Everything else dropped. |
  | Host OUTPUT | loopback, established, 443, 53, 123. Everything else dropped. |
  | FORWARD, inter-VM | the desktop may reach any `vmbr0` peer. No guest may reach the desktop, and no guest may reach another guest. |
  | FORWARD, egress | per R-00.2.6. |
  | NAT | MASQUERADE for `vmbr0` to the LAN; DNAT from the LAN for the desktop's SSH and RDP and for host SSH on 2222. |

* **R-01.10.3** Host SSH on port 22 is accepted from the desktop's address
  only. The control channel that creates and starts dev VMs is privileged;
  accepting host SSH from every guest would make the fleet's containment
  irrelevant, since any guest could then clone, start and configure a
  template.
* **R-01.10.4** The documented remote-access surface is: host SSH on 2222 from
  the LAN, host web UI on 8006 from the LAN, and desktop SSH or RDP DNAT'd
  from the LAN.

### R-01.11 The starting guest set is created unattended

* **R-01.11.1** vm 100 (`desktop`) and vm 101 (`llm`) are created and started
  during provisioning, with the iGPU and dGPU(s) attached respectively, an
  OS disk sized per Spec 00 §R-00.4, and a NoCloud seed attached (Spec 06).
* **R-01.11.2** vm 102 (`dev-template`) is created and started, **provisioned
  once, and then converted to a PVE template** (Spec 07 §6). It is never left
  as a running VM.
* **R-01.11.3** A template cannot be started directly. This is the mechanism
  that guarantees no dev VM is ever auto-started.
* **R-01.11.4** vm 103 and above are **not** created by host provisioning. They
  are created on demand from the desktop (Spec 07).
* **R-01.11.5** Re-running provisioning does not recreate a VM that already
  exists, and does not restart one that is already running.
* **R-01.11.6** Before the template is converted, the guest agent answers and
  the guest's first-boot log reports completion. Conversion proceeds only
  after that gate, so the template is never captured half-provisioned.
* **R-01.11.7** If the gate times out, the run logs a warning, leaves the VM
  running for the operator to finish by hand, and **continues** to the
  firewall step. The template is not converted from an unprovisioned disk.
* **R-01.11.8** The per-VM firewall flag is set on the guests whose egress is
  restricted.
* **R-01.11.9** **A host that cannot create a guest says so before any download
  or allocation is attempted, naming the missing prerequisite.** The guest set
  is created as a single unit, so a host that fails the check produces **no VMs
  at all** — and an assertion made only by the create call turns one wrong name
  into exactly that outcome, reported as a bare low-level error after the
  install media has been downloaded.
* **R-01.11.10** A missing bridge or storage is **reported for the operator to
  provide, never improvised.** Automatically adopting a network interface can
  take the host's only network path down — the same reason R-01.4.1 forbids
  target-disk detection.

## 3. Build

* **R-01.12.1** The build produces a single bootable ISO in an output
  directory outside version control.
* **R-01.12.2** The answer file and the first-boot bootstrap are rendered from
  committed templates, not hand-edited. A hand-edited value is one no build
  reproduces.
* **R-01.12.3** Rendering substitutes every identity, credential and disk
  token, and the build fails if any token survives. An unsubstituted
  `__PERSONALIZATION_PASSWORD_HASH__` in the shipped bootstrap is a host with
  no operator account; an unsubstituted `__ROOT_PASSWORD_HASH__` is a host
  whose root has no password.
* **R-01.12.4** A yescrypt hash survives rendering intact. An unescaped `$` in
  a hash is expanded away by the substitution, producing an install that
  validates, installs, and leaves nobody able to log in.
* **R-01.12.5** The bootstrap's staging directory is explicitly writable.
  The default staging area is the source ISO's own directory, which is mounted
  read-only, and the build fails there.
* **R-01.12.6** The build verifies the answer file before invoking the
  assistant, and tolerates the assistant's absence by reporting that the
  check was skipped — never by reporting success.

## 4. Invariants

* I-01.1 The install never prompts.
* I-01.2 The operator account exists on the host before the first network
  fetch is attempted.
* I-01.3 The root hash reaches `/etc/shadow` and nowhere else; no file the
  provisioner can read contains it.
* I-01.4 Only the pinned target disk can be written by the installer.
* I-01.5 No guest is created until IOMMU groups are verified separable.
* I-01.6 The dev template is a PVE template and cannot be started.
* I-01.7 The host firewall defaults to DROP in all three chains.
* I-01.8 A re-run of provisioning is safe.

## 5. Acceptance

| # | Check |
|---|---|
| A-01.1 | Boot the ISO on a conforming target. No prompt appears before the reboot. |
| A-01.2 | The operator account exists and works with the operator key, and `sudo` is passwordless for it. Its shadow hash matches `keys/personalization-password-hash`; host `root`'s is a different hash matching `keys/root-password-hash`. |
| A-01.3 | With the network unreachable, the operator account still exists and logs in. |
| A-01.4 | The answer file passes the 9.2 validator. It contains no `late-commands` section, no non-root user field, both not at once for the root password, and `first-boot.source` is `from-iso`. |
| A-01.5 | `disk-list` names exactly the configured device, and the build rejects each malformed variant in R-01.4.5. |
| A-01.6 | After reboot: the kernel command line carries the IOMMU flag for the detected CPU vendor, and the passthrough addresses show the `vfio-pci` driver in use while a retained GPU still shows its own. |
| A-01.7 | A deliberately non-separable IOMMU group aborts provisioning and names the group and its members. |
| A-01.8 | Memory: ZRAM and swap are active, the host cap is 2 GB, and guests have ballooning enabled. |
| A-01.9 | `qm list` shows 100 running, 101 running, 102 template, and no other VM. `qm start 102` is refused. |
| A-01.10 | `vmbr0` holds `192.168.100.1/24` with no physical port. dnsmasq is active, passes its configuration test, and answers for every VM's short and FQDN. The host's resolver is the local dnsmasq. |
| A-01.11 | All three filter chains default to DROP. INPUT accepts only the ports and sources in R-01.10.2; OUTPUT accepts only 443, 53 and 123. |
| A-01.12 | From the LAN: host SSH on 2222, host web UI on 8006, desktop SSH and desktop RDP all reachable. Host SSH on 22 is **not** reachable from the LAN. |
| A-01.13 | Host SSH on 22 **is** reachable from the desktop's address, and refused from another guest's. |
| A-01.14 | Per R-00.2.6: the desktop and vm 101 reach the LAN; vm 101 cannot reach a port other than 53/80/443; vm 103 reaches 53/80/443; a dev VM on 104 or above reaches nothing. |
| A-01.15 | No guest other than the desktop can reach another guest. |
| A-01.16 | The provisioning log is clean of errors, the unit is disabled, and the manifest records the media checksum and the resolved reference. |
| A-01.17 | Re-running the provisioner makes no destructive change. |
| A-01.18 | The build fails on an unsubstituted token and on a yescrypt hash mangled by substitution. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Versions, topology, memory and egress policy, sourcing and pinning rules |
| Spec 05 | Operator identity, the two-hash split, account-creation ordering |
| Spec 06 | How seeds and the login hash reach a guest; fragment execution order in detail |
| Spec 07 | `vmctl` account and keypair (fragment 25), the template conversion gate, dev VM creation |
| Spec 09 | Schema, lint, invariant and placeholder tests covering this spec's requirements |

## 7. Risks

| Risk | Mitigation |
|---|---|
| iGPU shares an IOMMU group with a host-critical device | Asserted at provisioning time (R-01.7); if it fails, the host must be reconfigured or rejected |
| Consumer GeForce driver refuses to run in a guest | Documented CPU-model override |
| Answer schema differs between PVE releases | Pinned 9.2 tool, `verify` in the build, and a build-time validation step |
| Host loses its console when the iGPU is passed | Expected; serial/IPMI is a stated precondition (R-01.6.7) |
| GitHub unreachable during provisioning | The operator account already exists (R-01.3.2); a vendored answer file is available for air-gapped install; fetches are small, logged and retried |
| Host and guests drift to different release references | One reference for the whole fleet, recorded in the manifest (R-00.8.2) |
| One hash file serves both credentials | Two files, two placeholders, and a test asserting each carrier receives only its own hash |
| Operator assumes a `sudo` user can reach the PVE web UI | A documented non-goal; realm access is a separate manual step on the live host |
