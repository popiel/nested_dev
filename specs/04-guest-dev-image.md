# Spec 04 — Guest: Dev VM image (Ubuntu Server 26.04, one project per VM)

Status: Draft (new; no predecessor — closes the `README.md` gap)
Pinned versions: Ubuntu Server **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**

## 1. Purpose and scope

Produce a golden QEMU disk (`dev-golden.qcow2`) for Proxmox **vm 102+**
(`dev-<project>`). Per `README.md`, each software dev VM hosts **only one
software project**, its network is **severely constrained**, and the VM is
**primarily disk storage + Docker engine** — all dev tasks (AI harness,
compiles, tests) run in **ephemeral Docker containers, often with
bind-mounted disk access**.

Neither `specs-mimo/` nor `specs-ds4/` specified this VM. This spec is new and
normative.

In scope: autoinstall `user-data`, Docker-only first boot, per-project
cloning contract, bind-mount + network-containment conventions,
build/cleanup. Out of scope: project code itself, LLM serving (Spec 03),
desktop access (Spec 02), host wiring (Spec 01 §5.3).

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Server **26.04 LTS** (same ISO as Spec 03, SHA256 pinned) |
| GPUs | **None** — no `hostpci` on dev VMs; GPU work goes via Spec 03 APIs |
| Runtime | Docker CE only (no NVIDIA toolkit, no CUDA, no Ollama in image or first boot) |
| Workspace | `/work/<project>` on OS disk (or attached `scsi1` per-project volume); bind-mounted into ephemeral containers, never copied into images |
| Network | Egress-deny default; allowlist only (Ubuntu archive + pinned upstreams + LLM-VM API peer); ingress SSH only |
| Account | `devuser`, SSH-key-only; `docker` group membership |
| OS disk | **40 GB** virtio thin (project data beyond that → per-project `scsi1` volume) |
| Fleet | Golden `dev-golden.qcow2` cloned per project: `102=dev-<alpha>`, `103=dev-<beta>`, …; `200–249` remain reserved future |
| Identity | No machine-specific data in golden image |

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-26.04-live-server-amd64.iso` | Official, same pin as Spec 03 |
| `dev/user-data/meta-data` | Empty |
| `dev/user-data/user-data` | Autoinstall (§4) |
| `dev/build-iso.sh` | Injects `autoinstall` param (same routes as Spec 02 §3) |
| `dev/dev-firstboot.sh` | Docker + hardening, fetched at `<REF>` |

## 4. `user-data` (representative, 26.04)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: dev-template
    username: devuser
    password: "CHANGE_ME_HASHED"
    realname: "Dev User"
  ssh:
    install-server: true
    allow-pw: false
  packages:
    - curl
    - ca-certificates
    - gnupg
    - git
    - qemu-guest-agent
  late-commands:
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /work && chown devuser:devuser /work && mkdir -p /etc/docker'"
```

Hostname, project volume, and firewall allowlist are set per-clone (§5), not
in the golden image.

## 5. First boot + per-project provisioning (`dev-firstboot.sh`)

Fetched at `<REF>`; logs to `/var/log/dev-firstboot.log`; self-disables.

1. Install Docker CE from `download.docker.com` (official upstream only);
   `usermod -aG docker devuser`; harden daemon
   (`overlay2`, `json-file` `10m×3`, `live-restore`); `systemctl enable docker`.
2. Harden host: `ufw default deny incoming; default deny outgoing; allow ssh
   in`; then allowlist egress: Ubuntu archive (`archive.ubuntu.com`,
   `security.ubuntu.com`), Docker Hub/registry endpoints in use, and the
   LLM-VM peer IP/port (e.g. `101:11434`) — everything else denied. PVE-level
   `firewall=1` on the `net0` device enforces the same. **Host-level
   enforcement**: the host's iptables OUTPUT chain drops all outbound from
   dev VMs by default (default-deny FORWARD + POSTROUTING MASQUERADE only
   applies to allowed traffic). The `ufw` rules inside the VM are a
   secondary defense; the host firewall is authoritative.
3. Per-project clone contract (run by operator/provisioner, not in golden):
   ```bash
   qm clone <dev-golden-vmid> 102 --name dev-alpha --full
   qm set 102 --memory 4096 --cores 4 --cpu host
   qm set 102 --ciuser devuser --sshkeys ~/.ssh/authorized_keys
   # optional per-project data volume:
   # qm set 102 --scsi1 local-lvm:50,size=100G  # mounted at /work/alpha
   qm start 102
   ```
   Set unique hostname, regenerate `machine-id`/SSH keys via cloud-init,
   mount `/work/<project>`, record project→VMID mapping in ops docs.
4. Ephemeral-container convention (documented, enforced by review):
   ```bash
   docker run --rm -it -v /work/alpha:/work -w /work \
     <pinned-toolchain-image> bash
   ```
   No long-lived mutable containers; no toolchain baked into the VM; state
   lives in `/work`, containers are disposable.

## 6. Image build + cleanup

Same discipline as Specs 02/03 §6: throwaway builder, `virt-sysprep`
(host keys, machine-id, logs, history), `zerofree`, output to
`output/dev-golden.qcow2` + SHA256 + `user-data` hash in `output/MANIFEST`,
delivered to `payloads/` for `import-from`/clone (Spec 01 §5.3).

## 7. Acceptance

* Unattended install; boot to console via `serial0`; no GPU devices
  (`lspci | grep -i 'vga\|3d'` empty except virtio).
* `docker run --rm hello-world` succeeds as `devuser`; daemon flags verified.
* Egress-deny holds: `curl` to archive/allowlisted endpoints succeeds,
  arbitrary egress fails; only SSH reachable inbound; PVE `firewall=1` set.
  Host iptables OUTPUT chain is the authoritative enforcement point.
* `/work` bind-mount workflow demonstrated with an ephemeral container; no
  project state inside container layers.
* Per-project clone produces unique hostname/keys/IP; golden has no identity.
* Rebuild at same REF reproduces (Docker pin recorded in MANIFEST).
