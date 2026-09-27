# Spec 04 — Guest: dev VM template and dev tooling

Status: Draft
Applies to: vm 102 `dev-template` and every dev VM cloned from it
Pinned versions: Ubuntu Server **26.04 LTS**, Proxmox VE **9.2**
Implementation: `dev/user-data/user-data`, `dev/dev-firstboot.sh`,
`dev/docker/`, `dev/tools/`, `provision/host/frag/30-create-guests.sh`

## 1. Scope

The dev template is the machine untrusted code runs on. It carries no GPU, no
inference stack, and no baked toolchain. It provides an isolated working
environment per project: a container runtime, a workspace, and a set of
tool wrappers that build their images on first use.

In scope: install seed content, container runtime, workspace and cache
contracts, the ephemeral-container tool pattern, base image policy, guest
firewall. Out of scope: when and how dev VMs are created (Spec 07), the
inference client configuration (Spec 03), the repository build tooling that
runs inside a dev VM (Spec 08).

## 2. Decisions

| Aspect | Choice |
|---|---|
| Base | Ubuntu Server 26.04 LTS, official ISO, the same media as Spec 03 |
| GPU | **None.** No device is passed through; GPU work goes through the LLM VM's API |
| Runtime | Docker CE only — no CUDA, no NVIDIA toolkit, no serving container |
| Java | JDK 21 LTS base image, shared by the Java, Scala and sbt images |
| Java/Scala dependency resolution | Managed inside the container, with the resolution cache bind-mounted so a second run is incremental |
| opencode | Runs in a container of its own, with the operator's configuration mounted **read-only** |
| Workspace | `/work`, bind-mounted into every container; project checkouts live here, never in an image |
| Build caches | Bind-mounted out of the containers that populate them |
| Tool wrappers | One script per tool in the account's own `PATH`, each building its image on first use |
| Tool image refresh | An explicit operator-invoked command, never automatic |
| Network | Ingress SSH only. Egress to DNS, HTTP and HTTPS only. Nothing else |
| Identity | The account from Spec 05; guest `root` locked; the account is in the container-runtime group |
| OS disk | 40 GB; larger projects attach their own volume |
| Template | Proxmox template, never a running VM. Clones are per project (Spec 07) |
| Console | Serial console, autologin as the account |

### 2.1 Why no GPU is passed through

A dev VM runs untrusted code, often in a container that a project controls. A
GPU passed into that VM is a GPU a project's container can drive, and the host
cannot then account for what runs on it. The dev VM reaches GPU capability
through the LLM VM's API over the private subnet, where the request is visible
and the hardware stays in a VM with no untrusted code on it.

## 3. Requirements

### R-04.1 Install

* **R-04.1.1** The template installs unattended from the official Ubuntu
  Server ISO with the host-assembled NoCloud seed (Spec 06). No image is built
  for it.
* **R-04.1.2** The seed carries the account identity, the operator and
  guest-identity keys, the account's UID and GID, guest `root` locked, the
  workspace directory, and the minimum packages to reach the network and the
  guest agent.
* **R-04.1.3** The account's UID and GID are set before the workspace is
  created or owned.
* **R-04.1.4** SSH password authentication is disabled, so the two injected
  public keys are the only way in.
* **R-04.1.5** A serial console is enabled and autologs the account, and the VM
  is created with a serial console socket and no emulated display.

### R-04.2 One template, many dev VMs

* **R-04.2.1** The template is provisioned **once**, then converted to a
  Proxmox template and never started again directly.
* **R-04.2.2** Every dev VM is a clone of that template. Dev VMs are therefore
  identical at creation and differ only by name, address and attached volumes.
  A per-project tool change is a template change, not a change to one project.
* **R-04.2.3** The template's final hostname is the dev-VM hostname, not the
  template's install-time hostname. A clone whose hostname still says it is a
  template reports the wrong name in every log and every DNS lookup.
* **R-04.2.4** Clones do not run first-boot configuration again: the unit was
  disabled in the template (R-04.7.1). A clone is provisioned the moment it is
  created, not on its first boot.

### R-04.3 Container runtime, and what the account may do with it

* **R-04.3.1** The container runtime is installed at first boot from the
  vendor's own repository, after any conflicting distribution packages are
  removed.
* **R-04.3.2** Container log rotation is bounded and the storage driver is
  explicit. An unbounded JSON log on a VM that runs long-lived build containers
  eventually fills a 40 GB disk with logs.
* **R-04.3.3** The runtime restarts a crashed container's processes rather than
  leaving the VM in a half-dead state. This is the one place the fleet
  deliberately trades strict isolation for availability: a dev VM that must be
  repaired by hand after an OOM kill is a dev VM that gets left broken.
* **R-04.3.4** The account is a member of the container-runtime group, so the
  operator can run containers without elevation. The consequence — that
  membership is effectively root on that guest — is accepted and stated: this
  is the isolation boundary for untrusted work, not a hardened multi-tenant
  host.
* **R-04.3.5** A non-responsive runtime after install is reported as a warning
  and does not abort provisioning. The image definitions and wrappers are still
  worth installing, and the next boot can retry.

### R-04.4 The workspace is the only mutable state

* **R-04.4.1** `/work` exists on every dev VM, is owned by the account, and is
  the bind-mount target for every tool container. A project checkout is made
  there.
* **R-04.4.2** No project file is ever copied into a tool image. An image that
  carries a checkout is an image that is stale the moment the project changes.
* **R-04.4.3** The current working directory is bind-mounted as the working
  directory inside the container, so a tool sees the same paths it would
  outside and its output lands where the operator expects.

### R-04.5 Build caches live outside the containers

* **R-04.5.1** The dependency-resolution caches for the JVM ecosystem and the
  tool configuration are bind-mounted from the account's home into the
  containers that use them, and are created and owned by the account at first
  boot.
* **R-04.5.2** A cache that is not bind-mounted is lost on every container exit,
  so the second run of any build re-downloads everything. The first run is
  slow by design; every later run is not.
* **R-04.5.3** The tool configuration is mounted **read-only** into the tool
  container. That container runs the agent a project's build can influence;
  letting it rewrite the operator's configuration would let a project change
  how the next run behaves.

### R-04.6 Tool wrappers build their images on first use

* **R-04.6.1** One wrapper exists per tool: Java, Scala, sbt, opencode, and the
  repository build tool.
* **R-04.6.2** Each wrapper builds its image on first invocation, then runs the
  tool in an ephemeral container over the bind-mounted workspace. Tool images
  are therefore absent from a fresh dev VM by design.
* **R-04.6.3** Because the images are built on demand, a dev VM's first
  invocation of each tool is slow. This is traded for a template that stays
  small and a base-image change that is picked up without re-cloning every dev
  VM.
* **R-04.6.4** Image definitions are installed from the **same resolved
  reference** as the first-boot script, and that reference is recorded in the
  template. Fetching them from a branch name means the template's tool images
  and the script that installs them can come from different commits, and the
  mismatch is invisible.
* **R-04.6.5** The repository build tool's wrapper requires a checkout at a
  known path inside the workspace, and says so when it is absent, naming the
  command that creates it. It does not clone on the operator's behalf.
* **R-04.6.6** A tool's container runs under the account's identity, and the
  image is built with that identity, so files produced inside the container are
  owned by the operator rather than by a numeric uid the operator cannot
  interpret.
* **R-04.6.7** The wrappers are on the account's `PATH` for interactive shells.
  A wrapper installed but not on `PATH` is a wrapper the operator does not have.

### R-04.7 First-boot provenance and completion

* **R-04.7.1** The first-boot unit is disabled on success, so a clone does not
  re-run it. Its log line announcing completion is the host's signal that the
  template is safe to convert (R-01.11.6).
* **R-04.7.2** The first-boot script, the personalization file, and the two
  repository tool scripts are all present in the guest, at the same reference.
  A first-boot script that silently cannot find a tool it is supposed to
  install produces a dev VM that looks provisioned and is not.
* **R-04.7.3** Base images are pulled at first boot, in parallel, and the
  resolved digest of each is recorded in the log. A failed pull is a warning:
  the wrapper that needs that base builds its image and pulls at that point.
* **R-04.7.4** The base image set is: a JDK 21 LTS image, a slim Node image, a
  slim Python image, and the tool agent's own image. All four come from their
  publishers' registries, none from this repository.
* **R-04.7.5** Refreshing tool images against new base layers is an explicit
  operator command that rebuilds every tool image and appends the resulting
  digests to a manifest in the account's own storage. It is never automatic:
  a silent rebuild changes what a project's build sees without the project
  changing.

### R-04.8 Guest firewall

* **R-04.8.1** Incoming traffic is denied by default; SSH is the only accepted
  ingress. A dev VM is not a service.
* **R-04.8.2** Outgoing traffic is denied by default, with DNS, HTTP and HTTPS
  accepted. A dev VM that pulls images and packages needs those three and
  nothing else.
* **R-04.8.3** The host's forwarding chain enforces the same policy
  independently, and is the authority (Spec 00 §R-00.2.6). A guest firewall
  that permits more than the host forwards changes nothing; one that permits
  less than an operator expects produces a confusing failure, so both are
  stated.
* **R-04.8.4** Guest `root` is locked.

### R-04.9 Sizing

* **R-04.9.1** A dev VM receives 8 GB and 4 cores and a single 40 GB OS disk.
  The memory is deliberately small relative to the desktop and the LLM VM: dev
  work is a container over a bind-mounted checkout, not an in-guest toolchain.
* **R-04.9.2** Project data lives under the workspace on that one disk. The
  clone contract attaches no second disk, so a project that outgrows 40 GB has
  to be given storage by hand. This is a known gap, not an intended design;
  see Spec 07 §7.
* **R-04.9.3** There is no native toolchain on the dev VM's filesystem, and
  none is installed by any provisioner. A script that installed build tools
  directly on the guest would defeat the container boundary this spec exists
  to maintain.

## 4. Invariants

* I-04.1 No dev VM ever has a GPU attached.
* I-04.2 No toolchain is installed on the dev VM's own filesystem; every tool
  runs in a container.
* I-04.3 No tool image contains project files.
* I-04.4 Every dev VM is a clone of the one template and is created already
  provisioned.
* I-04.5 The template is never running.
* I-04.6 A dev VM's only ingress is SSH and its only egress is DNS, HTTP and
  HTTPS.
* I-04.7 A dev VM's login credential is never usable for fleet control.

## 5. Acceptance

| # | Check |
|---|---|
| A-04.1 | The template installs unattended and reaches a working login on the serial console with no prompts. |
| A-04.2 | The account exists with the configured UID, GID, home and shell; guest `root` is locked; SSH password authentication is refused. |
| A-04.3 | `/work` exists and is owned by the account. No project file is present in any image. |
| A-04.4 | No NVIDIA, CUDA or serving container is present on the dev VM, and no host PCI device is attached. |
| A-04.5 | After the template is converted, a fresh clone boots with the first-boot unit already disabled and does not re-run it. |
| A-04.6 | A fresh clone's hostname is its dev-VM name, not the template's install-time name. |
| A-04.7 | Each of Java, Scala, sbt, opencode and the repository build tool is invocable by name from an interactive shell. |
| A-04.8 | The first invocation of each tool builds its image; the second invocation does not rebuild. |
| A-04.9 | A file written by a tool in the workspace is owned by the account on the host side of the mount. |
| A-04.10 | The second run of a JVM build reuses the mounted cache and does not re-download dependencies. |
| A-04.11 | The tool agent's configuration is mounted read-only; a write from inside the container fails. |
| A-04.12 | The repository build tool reports the clone command when no checkout is present, and does not clone by itself. |
| A-04.13 | The first-boot log records the resolved digest of each base image, and the guest holds both repository tool scripts. |
| A-04.14 | The template's installed image definitions resolve to the same reference recorded for the first-boot script. |
| A-04.15 | Running the refresh command rebuilds every tool image and appends digests to the manifest; no rebuild happens on its own. |
| A-04.16 | The firewall refuses unsolicited inbound, accepts SSH, and permits only DNS, HTTP and HTTPS outbound. |
| A-04.17 | The host's forwarding chain independently blocks every other destination from the dev VM. |
| A-04.18 | The dev VM's account cannot perform any fleet lifecycle operation. |
| A-04.19 | A dev VM has 8 GB, 4 cores and a 40 GB OS disk, and no device is passed through to it. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Topology, memory profiles, egress policy, sourcing and pinning |
| Spec 01 | Template creation and the conversion gate |
| Spec 03 | The inference API this VM's workloads call instead of owning a GPU |
| Spec 05 | Account identity, UID/GID, locked root, key injection |
| Spec 06 | Seed assembly, placeholder injection, the clone contract |
| Spec 07 | Clone names, addresses, volumes, lifecycle, the credential matrix |
| Spec 08 | The repository build tool that runs inside a dev VM |
| Spec 09 | Seed, first-boot and wrapper static checks |

## 7. Risks

| Risk | Mitigation |
|---|---|
| A project's build code gains host-level access to its dev VM | Accepted and stated (R-04.3.4). The dev VM is the boundary; the host and the other guests are not reachable from it |
| A project's build reaches the GPU | No GPU is passed through (R-04.1.2, §2.1); GPU work goes through the LLM VM's API |
| Tool images and the script that installs them come from different commits | Both are fetched at one resolved reference, which is recorded (R-04.6.4) |
| A tool image silently carries a stale checkout | Project files are never copied into an image (R-04.4.2) |
| Container logs fill the 40 GB disk | Log rotation is bounded (R-04.3.2) |
| A project outgrows the single 40 GB disk | A known gap: the clone contract attaches no second disk, so storage is added by hand (R-04.9.2, Spec 07 §7) |
| A native toolchain is installed on the guest by some provisioner | No provisioner installs one, and a script that did would break the container boundary (R-04.9.3) |
| A first boot that cannot find the tool scripts leaves a half-provisioned VM | The scripts are fetched by the seed at the same reference, and the first-boot log names any that is missing (R-04.7.2) |
| Automatic base-image refresh changes a project's build without the project changing | Refresh is operator-invoked and logged (R-04.7.5) |
| A dev VM is used as a proxy out of the private subnet | Egress is limited to three destinations by two independent layers (R-04.8.2, R-04.8.3) |
