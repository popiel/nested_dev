# Spec 02 — Guest: Desktop VM image (Ubuntu Desktop, iGPU owner)

Status: Draft

## 1. Purpose and scope

Produce a golden QEMU disk (`desktop-golden.qcow2`) for Proxmox **vm 100**.
The VM owns the host's motherboard iGPU via VFIO passthrough, drives local
monitors connected to the motherboard, and serves the same desktop over RDP.

In scope: autoinstall `user-data`, ISO customization, image build and cleanup.
Out of scope: host-side VM wiring (Spec 01 §5.2), RDP access control policy.

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Desktop 24.04 LTS (amdgpu-free; iGPU is Intel/AMD-on-motherboard) |
| Session | GNOME Wayland (native); fallback Xorg + xrdp |
| RDP | `gnome-remote-desktop` (grd) primary; `xrdp` as fallback |
| Desktop account | single `deskuser`, autologin optional (do not autologin if Wayland security is a concern) |
| Disk | 60 GB virtio (system) — desktop needs no more; user data on `vmbr`-routed shares later |
| Identity | NO machine-specific data (see §6 cleanup) |

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-24.04.2-desktop-amd64.iso` | official, pinned + SHA256 recorded in `build-iso.sh` |
| `user-data/meta-data` | empty (NoCloud seed marker) |
| `user-data/user-data` | autoinstall config (Section 4) |
| `build-iso.sh` | injects `autoinstall` kernel args into ISO grub/isolinux entries AND/OR provisions an HTTP `cidata` seed |

Which injection route:
- Embedded: unpack ISO to `iso/`, append ` autoinstall ds=nocloud\;/cdrom/` to the
  `linux` lines in `isolinux/txt.cfg` and `boot/grub/grub.cfg`, drop `user-data` at
  the ISO root, repack (xorriso). Rebuild ISO per change.
- HTTP (recommended for fleet): boot stock ISO with
  `autoinstall ds=nocloud;s=http://<docroot>/desktop/` (who-server delays) — keep
  `user-data` in the docroot so edits don't rebuild the ISO; the ISO only gains the
  `autoinstall` param. Use the stock ISO's PXE-preseed entry or a thin iPXE shim.

## 4. `user-data` (representative)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: desktop-vm
    username: deskuser
    password: "CHANGE_ME_HASHED"
    realname: "Desktop User"
  ssh:
    install-server: true
    allow-pw: false
  packages:
    - gnome
    - gnome-remote-desktop
    - xrdp
    - xorgxrdp
    - pipewire
    - network-manager
    - firmware-linux            # microcode/drivers incl. i913/gpu fw
  late-commands:
    - "curtin in-target --target=/target -- systemctl enable grd.service"
    - "curtin in-target --target=/target -- systemctl enable xrdp"
    # RDP user credential is per-session (grdctl rdp set-credentials).
    # On image build there is no interactive session; see §5 for the
    # provisioning step that runs grdctl rdp enable-rdp + set-credentials
    # as deskuser on first login (or via a systemd user unit seeded here).
```

Notes:
- `gnome-remote-desktop` on Wayland: verified workflows script
  `grdctl rdp enable` + `grdctl rdp set-credentials <user> <pwd>` under the
  target user's session. Because the golden image has no session, treat the RDP
  credential step as **first-boot configuration** (Section 5) rather than part of
  the image layer — document where the secret is injected (not in the image).
- Fallback `xrdp`: requires the user session manager; typically an Xorg GDM
  session (`xorgxrdp`) when Wayland `grd` is unavailable. Keep both installed;
  pick in `first-boot.sh` by probing `echo $XDG_SESSION_TYPE`.
- Firewall inside guest: allow `3389/tcp` on `vmbr0` only.
- The guest sees the passed-through Intel iGPU as a real PCI device; **no
  special driver provision is needed in the image** — `firmware-linux` covers
  firmware that ships with Mesa/dri from the desktop install.

## 5. First-boot guest turns (runs inside VM 100)

A tiny trivial script seeded via `late-commands` or `cloud-init` (review on
secure mode) shall:

1. Detect the display device: `lspci | grep -i vga` must show the Intel
   iGPU vendor line (proves passthrough).
2. Start `gnome-remote-desktop`, run `grdctl rdp enable-rdp` and
   `grdctl rdp set-credentials` from a policy secret source (Hashicorp/KV, or an
   env secret), open `3389`.
3. If Wayland session absent, fall back to enabling `xrdp` session.

## 6. Image build + cleanup

Build inside a throwaway builder (e.g., a transient KVM/libvirt VM or Proxmox
scratch machine) to keep the image free of builder residue.

1. Run installer from the prepared ISO with the `user-data` docroot mounted.
2. On completion, shut down, then `virt-sysprep` (libguestfs):
   - remove SSH host keys, `/etc/machine-id`, log files, bash history;
   - unset saved hostname/IP state (rely on cloud-init);
   - zero free space (`zerofree`) for compressible qcow2.
3. Output `output/desktop-golden.qcow2`; record SHA256 alongside the `user-data`
   used, in `output/MANIFEST`.
4. Upload to the PVE host's storage (or the docroot `payloads/`) for
   `qm ... import-from` per Spec 01 §5.2.

## 7. Acceptance

- Unattended boot of ISO → desktop VM boots to a login screen with no prompts.
- `lspci`/`lshw` inside VM 100 show the Intel VGA; monitors on the motherboard
  light up once `hostpci0` is attached (Spec 01).
- RDP from LAN reaches the desktop; session type is Wayland (grd) or Xorg
  (xrdp fallback) reliably.
- Golden image contains no SSH host keys / machine-id / plaintext credential:
  greps across `/etc/ssh*`, `/var/lib/cloud*`, `grdctl view-cert` output <empty
  beyond seed>.
- Rebuilding from `student ISO + user-data` reproduces bit-wise results within
  a known-good nondeterminism window (kernel/module versions pinned via
  `restricted` repo snapshot if needed).