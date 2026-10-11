# Spec 07 — Dev VM fleet lifecycle and control plane

Status: Draft
Applies to: vm 102 `dev-template` and the dev VMs at 103 and above
Pinned versions: Proxmox VE **9.2**
Implementation: `desktop/devctl`, `provision/host/frag/25-desktop-control.sh`,
`provision/host/vmctl/vmctl-host`, `provision/host/vmctl/sudoers`

## 1. Scope

How a dev VM comes into existence, how it is addressed, how it is operated
from the desktop, and — most importantly — which credentials may do what.

In scope: the control credentials, the host-side control program, the
`devctl` interface, the clone contract, addressing and naming, the dev VM ID
range, and the audit log. Out of scope: the template's contents (Spec 04), the
host firewall (Spec 01), the desktop's own installation (Spec 02).

## 2. Decisions

| Aspect | Choice |
|---|---|
| Operator | The desktop, through `devctl`. No lifecycle access from any other guest |
| Dev VM IDs | 103 and above, up to 249. 100–102 are the static fleet |
| Dev VM name | `dev-<project>`, derived from the project name at creation |
| Address | `192.168.100.<vmid>`, the last octet of the ID |
| MAC | Derived from the dev VM ID, so a clone never collides with its siblings |
| Hostname | Matches the registered name, set on first start once the guest agent answers |
| DNS | Registered on the host for both the short name and the fleet domain |
| Control credential | A dedicated account whose only capability is the control program |
| Host-root credential | The desktop guest-identity key, pinned to the desktop's address |
| Guest shell access | The desktop guest-identity key, not the control credential |
| Audit | Every accepted and every rejected control operation is logged on the host |

### 2.1 The credential matrix

This is the security core of the fleet. Three credentials, three different
blast radii:

| Credential | Lives on | Can do | Cannot do |
|---|---|---|---|
| Filbert operator key | Operator's machine (Filbert), trusted by the host account + host root + desktop account | Log in to host and desktop directly | Reach LLM/dev guests directly (proxied via desktop; host uses `qm guest exec`) |
| Desktop (guest-identity) key | Desktop only (private half seeded there) | Open a shell in any guest as the account; host `root` from the desktop's address only | Operate the fleet through the control program |
| Control key | Desktop only | List, inspect, start, stop, create and read logs of dev VMs — through the control program and nothing else | Open a shell on the host; touch any VM outside the dev range; do anything the control program does not implement |

The separation is the point. The control key is what fleet automation would
hold; giving it a shell would turn a bug in one project's dev VM into root on
the hypervisor. The desktop key is the operator's escape hatch and is
deliberately the most powerful credential in the fleet, which is why its host-
root use is pinned to one address.

## 3. Requirements

### R-07.1 The control account can only run the control program

* **R-07.1.1** A dedicated, non-human account on the host exists solely to
  carry the control key. It has a locked password and is reachable by key only.
* **R-07.1.2** The control credential can invoke the control program and
  nothing else: any client-requested command is replaced by the forced
  command with the client's string passed as arguments, and all forwarding
  is disabled.
* **R-07.1.3** The control account has a working login shell, because the
  forced command executes through it: a shell that refuses to run fails the
  entire control channel closed with an error that looks like a permissions
  problem. Current mechanism: real shell, never a "no login" shell.
* **R-07.1.4** The control credential cannot escalate or persist its own
  privilege: the control program is host-owned and not writable by the
  account, and unprivileged invocation fails every verb instead of silently
  degrading. Current mechanism: sudo-mediated invocation with exactly the
  wrapper granted and only the verb channel (`SSH_ORIGINAL_COMMAND`)
  preserved.
* **R-07.1.5** The account is created idempotently, including correcting a
  shell left wrong by an earlier run.

### R-07.2 The control program is the whole surface

* **R-07.2.1** The host-side control program accepts exactly these
  operations: list, status, start, graceful stop, forced stop, create, and read
  a guest log. Anything else is refused and logged as refused.
* **R-07.2.2** Every operation that takes an ID validates that it is numeric
  **and** inside the dev range before acting on it. The dev range starts above
  the static fleet, so an out-of-range ID cannot reach the desktop, the LLM VM
  or the template even if the range check is somehow skipped.
* **R-07.2.3** Starting a dev VM additionally requires that the ID's VM is
  currently stopped and that its name matches the dev naming pattern. Both
  checks exist because a name change is how a VM would be moved across the
  fleet's trust boundary.
* **R-07.2.4** Operator-supplied text never reaches hypervisor tooling
  unvalidated. Current mechanism: project names and IDs pattern-checked
  first.
* **R-07.2.5** Reading a guest log degrades to a clear runnable-state message
  when the VM is stopped or its agent is not up yet. Current mechanism: read
  through the guest agent.
* **R-07.2.6** A missing control program fails provisioning loudly: every
  control verb would otherwise fail against a forced command that does not
  exist, surfacing on the desktop as an unexplained channel failure.
  Current mechanism: fixed install path; missing source is fatal.

### R-07.3 `devctl` is the desktop's interface

* **R-07.3.1** The desktop documents, in its own help, which operations are
  restricted and which are full-privilege, so the operator sees the privilege
  split without reading source. Current mechanism: subcommands grouped by
  credential in `devctl` help.
* **R-07.3.2** A VM may be named by its name or by its ID, for every operation
  that takes one. Requiring the operator to remember IDs is how IDs get copied
  wrong.
* **R-07.3.3** Unknown names are reported as unknown against the host's own
  listing, never passed through. Current mechanism: name resolution via the
  control channel's listing.
* **R-07.3.4** Starting a dev VM tells the operator that the first boot takes
  several minutes and how to watch it. A start that returns instantly looks
  like it failed.
* **R-07.3.5** Guest shells use the guest credential and address the guest
  directly, never a control credential. Current mechanism: guest-identity key
  to the guest's own address.
* **R-07.3.6** Running a command on the host uses the desktop (host-root) credential, and
  requires the guest-identity key to be present. Both operations fail with a
  named error naming the missing key rather than an opaque SSH failure.
* **R-07.3.7** The wrapper takes the guest account name from its environment
  and refuses to run without it, rather than embedding a name that a
  personalization change would silently invalidate.
* **R-07.3.8** Errors the operator can act on name the thing to check: a
  missing key names the log to read; an unknown VM names what was asked for.

### R-07.4 The clone contract

* **R-07.4.1** Creating a dev VM requires a project name, which is validated as
  a short lowercase name and is the only operator-supplied free text in the
  whole control path.
* **R-07.4.2** The next free ID in the dev range is allocated, and the range
  being exhausted is an explicit error rather than an ID outside the range.
* **R-07.4.3** The dev VM is a full clone of the template. It is created
  **stopped** and never started by the create operation, so a VM that is
  created is not yet running, untrusted code.
* **R-07.4.4** A created VM's name, address, link address and registered
  hostname all derive deterministically from its project and ID, so no two
  siblings collide. Current mechanism: `dev-<project>`, last-octet-equals-ID
  address, ID-derived MAC, fleet hostname.
* **R-07.4.5** The host's forwarding policy applies to every dev VM interface.
  Current mechanism: interface marked firewall-managed (R-01.11.9).
* **R-07.4.6** A created VM is immediately reachable by both its names: the
  address lease, both resolutions and the inventory row are all written before
  success is reported. Current mechanism: registration atomic with creation.
* **R-07.4.7** The host's name service is reloaded after registration, so the
  new name resolves without waiting for a restart.
* **R-07.4.8** The fleet is reconstructible from one record per VM carrying
  ID, name, hostname, address, MAC, status and project. Current mechanism:
  inventory row.
* **R-07.4.9** A started clone reports its registered name without delaying
  the start for agent readiness. Current mechanism: hostname set once the
  guest agent first answers, in the background.
* **R-07.4.10** A guest agent that never answers is a logged warning, not a
  failed start. The VM is running and usable; only its self-reported name is
  wrong, and the log says exactly which VM and what to run.

### R-07.5 Addressing and naming

* **R-07.5.1** Every fleet VM has a fixed address, and the address is derivable
  from the ID. Nothing in the fleet depends on DHCP-assigned addresses.
* **R-07.5.2** Every fleet VM resolves by short name and by fleet domain, on the
  host and in every guest, through the host's name service.
* **R-07.5.3** The static fleet's entries are fixed at install time; dev VM
  entries are appended. A re-provision does not drop the appended entries.
* **R-07.5.4** A dev VM's MAC is unique among the fleet by construction, so a
  clone's name and address cannot be confused with a sibling's.

### R-07.6 The host-root (desktop) credential is address-pinned

* **R-07.6.1** The host `root` credential is usable only from the desktop:
  the same key presented from any other address is refused. Current
  mechanism: guest-identity trust entry pinned with `from="<desktop-IP>"`.
* **R-07.6.2** The host-`root` credential cannot be repurposed to pivot out
  of the private subnet. Current mechanism: forwarding options on the trust
  entry match the control credential's.
* **R-07.6.3** The desktop's address is asserted against the host's name-service
  configuration by a test, because the pin and the lease must agree. If the
  desktop's address ever changes and only one of the two is updated, the key is
  still present and access still silently fails.
* **R-07.6.4** Re-trusting is idempotent: a re-run never stacks a second
  entry. Current mechanism: content-checked append.

### R-07.7 Staged key material

* **R-07.7.1** Re-provisioning never invalidates credentials guests already
  trust. Current mechanism: control and guest-identity keypairs generated
  once on the host in a root-only location and retained.
* **R-07.7.2** Their private halves are staged for the desktop seed and
  destroyed once the seeds are built (Spec 06 §R-06.6).
* **R-07.7.3** The guest-identity key is a **different key** from the control
  key. The control key cannot be used to open a guest shell, and the
  guest-identity key cannot operate the fleet. One key serving both purposes
  would make the forced-command restriction the only thing standing between a
  leaked credential and a host shell.

### R-07.8 Audit

* **R-07.8.1** Every accepted operation is logged on the host with the
  operation, the ID and, where relevant, the name.
* **R-07.8.2** Every refused operation is logged as refused, with the reason.
  A refusal log is what makes an attempt to reach a non-dev VM visible.
* **R-07.8.3** Control history and provisioning history are separable: the
  control channel lives for the life of the fleet while provisioning runs
  once. Current mechanism: separate control log.
* **R-07.8.4** Audit distinguishes which credential class acted.
  Current mechanism: control vs administrative operations logged distinctly.

### R-07.9 Sizing and limits

* **R-07.9.1** The dev range holds 147 IDs, 103 through 249, matching the
  addressing scheme's usable range.
* **R-07.9.2** The dev range is closed. The operator can add dev VMs; nothing
  in the fleet can address a VM outside the range.

## 4. Invariants

* I-07.1 Only the desktop holds a credential that can operate the fleet.
* I-07.2 The fleet control credential cannot open a shell on the host.
* I-07.3 No dev VM can address or operate any VM outside the dev range.
* I-07.4 A newly created dev VM is stopped.
* I-07.5 A dev VM is always a clone of the one template.
* I-07.6 Every fleet VM is addressable by name and by fixed address.
* I-07.7 Every control operation, accepted or refused, is logged.
* I-07.8 The template is never started.

## 5. Acceptance

| # | Check |
|---|---|
| A-07.1 | The control account exists with a locked password, a real login shell, and a key entry carrying a forced command plus the three forwarding restrictions. |
| A-07.2 | The control credential can list, inspect, start, stop, create and log. It cannot open an interactive shell, and an attempted shell is replaced by the forced command. |
| A-07.3 | The control program is present and root-owned; the control account cannot replace it. |
| A-07.4 | A missing control program in the provision tree aborts provisioning with a named error rather than a warning. |
| A-07.5 | Every control verb accepts a name or an ID and reports an unknown name as unknown. |
| A-07.6 | A non-numeric ID, and an ID for the desktop, the LLM VM or the template, are all refused and logged as refused. |
| A-07.7 | Starting a VM whose name does not match the dev pattern is refused and logged. Starting an already-running VM is refused. |
| A-07.8 | An unrecognised verb is refused and logged. |
| A-07.9 | A dev VM is created stopped, with the dev name pattern, an address whose last octet is its ID, a MAC derived from that ID, and a firewall-managed interface. |
| A-07.10 | Immediately after creation the new VM resolves by short name and by fleet domain from the host and from another guest, without a restart. |
| A-07.11 | The inventory has exactly one row for the new VM, with the ID, name, hostname, address, MAC and project. |
| A-07.12 | After the first start, the dev VM's own hostname matches its registered name, and the start command returned before the agent answered. |
| A-07.13 | With the agent withheld, the start still succeeds, and the log names the VM and the command to set the name by hand. |
| A-07.14 | The inventory's static rows survive a re-provision. |
| A-07.15 | A dev VM's MAC differs from every other fleet VM's. |
| A-07.16 | The guest-identity key opens a shell in a guest; the control key does not. |
| A-07.17 | Host `root` over the desktop credential works from the desktop and is **refused** from another guest, using the same key. |
| A-07.18 | Re-running provisioning does not regenerate either keypair, and does not duplicate the host's trust entry. |
| A-07.19 | The test that asserts the host-root pin matches the name-service lease fails when either one is changed alone. |
| A-07.20 | The control log shows accepted and refused operations, and distinguishes control operations from administrative ones. |
| A-07.21 | The dev range is exhausted: the create operation reports that no ID is free. |
| A-07.22 | `devctl` refuses to run with no account name in its environment, and an unknown verb prints the grouped help. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Topology, addressing, the dev range, egress policy |
| Spec 01 | Fragment 25, the firewall flags on dev VMs, host `root` reachability from the desktop |
| Spec 02 | The desktop as the operator of this interface; `devctl` installation |
| Spec 04 | The template these VMs are cloned from; what a clone already has |
| Spec 05 | Key generation, staging, destruction, the two-credential split |
| Spec 06 | Seed injection of the two private key halves |
| Spec 09 | Credential-split, range-boundary and pin-consistency tests |

## 7. Risks

| Risk | Mitigation |
|---|---|
| A leaked control key becomes a host shell | The credential is forced-command-only with a real shell, so a shell is not reachable (R-07.1.2, R-07.1.3). A "no login" shell is not used, because it would break the control channel in a way that looks like a permissions fault |
| A project compromises its dev VM and pivots to the host | No dev VM holds a control or host-root credential, and dev VMs cannot address anything outside their range (I-07.1, I-07.3) |
| A leaked desktop key is usable from any guest | The host trust entry is pinned to the desktop's address (R-07.6.1) |
| The desktop's address changes and the pin and the lease disagree | A test asserts the two agree, and a re-run does not duplicate the entry (R-07.6.3) |
| A missing control program looks like a control-channel failure | Its installation is fatal, naming the consequence (R-07.2.6) |
| A dev VM reports the template's hostname | The name is set once the agent answers, and an unanswered agent is a named warning (R-07.4.9, R-07.4.10) |
| An ID outside the dev range is operated | Two independent checks, and the range starts above the static fleet (R-07.2.2) |
| Operator-supplied text reaches the hypervisor tooling | Project names are pattern-checked before use (R-07.2.4) |
| A control operation is attempted and leaves no trace | Accepted and refused operations are both logged (R-07.8.1, R-07.8.2) |
