# Spec 02 — Guest: Desktop VM image (Ubuntu Desktop 26.04, iGPU owner)

Status: Draft (merged)
Pinned versions: Ubuntu Desktop **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**

## 1. Purpose and scope

Produce a golden QEMU disk (`desktop-golden.qcow2`) for Proxmox **vm 100**.
The VM owns the motherboard iGPU via VFIO, drives local board outputs where
attached, and serves the desktop over RDP on `:3389`.

In scope: autoinstall `user-data`, ISO customization, first-boot RDP wiring,
image build/cleanup. Out of scope: host-side VFIO/VM wiring (Spec 01 §5),
RDP access-control policy.

Supersedes `specs-mimo/vm-desktop.md` (XFCE-only, FAI-baked, user `ubuntu`,
30 GB) and `specs-ds4/02-guest-desktop-image.md` (GNOME/grd-only, 24.04,
user `deskuser`, 60 GB). Default below is the lightweight path; the other is
a retained profile.

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Desktop **26.04 LTS** (official `ubuntu-26.04-desktop-amd64.iso`, SHA256 pinned in `build-iso.sh`) |
| Session (default) | **XFCE + xrdp/Xorg** (16 GB friendly; from mimo) |
| Session (optional profile) | GNOME Wayland + `gnome-remote-desktop` primary, xrdp fallback (from ds4; use on 32 GB hosts or where HW-encode wanted) |
| Account | single `deskuser` (ds4 name wins; mimo `ubuntu` rejected), SSH-key-only, autologin off |
| Disk | **40 GB** virtio system (compromise: mimo 30 GB too tight for 26.04 + browsers, ds4 60 GB oversized for thin hosts) |
| Identity | NO machine-specific data (§6 cleanup) |
| iGPU driver | **No special driver baked in.** Intel: `mesa`/`intel-media-va-driver` from archive; AMD APU: `xserver-xorg-video-amdgpu` + `mesa`. Installed via `packages:` / first-boot from official archive only |

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-26.04-desktop-amd64.iso` | Official, pinned + SHA256 in `build-iso.sh` |
| `desktop/user-data/meta-data` | Empty (NoCloud seed marker) |
| `desktop/user-data/user-data` | Autoinstall config (§4) |
| `desktop/build-iso.sh` | Injects `autoinstall` kernel args into ISO grub/isolinux AND/OR provisions HTTP `cidata` seed |
| `desktop/first-boot.sh` | RDP/session wiring, fetched inside VM 100 on first boot at pinned `<REF>` |

Injection routes (same as ds4, versions bumped):

* Embedded: unpack ISO, append ` autoinstall ds=nocloud\;/cdrom/` to `linux`
  lines in `isolinux/txt.cfg` + `boot/grub/grub.cfg`, drop `user-data` at ISO
  root, repack (xorriso). Rebuild ISO per change.
* HTTP (recommended): boot stock ISO with
  `autoinstall ds=nocloud;s=http://<docroot>/desktop/`; keep `user-data` in
  docroot so edits don't rebuild the ISO.

## 4. `user-data` (representative, 26.04)

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: desktop-vm
    username: deskuser
    password: "CHANGE_ME_HASHED"   # prefer ssh-only
    realname: "Desktop User"
  ssh:
    install-server: true
    allow-pw: false
  packages:
    - xfce4
    - xfce4-goodies
    - xfce4-terminal
    - thunar
    - mousepad
    - xrdp
    - xorgxrdp
    - firefox
    - mesa-utils
    - intel-media-va-driver-non-free   # Intel path; harmless if AMD (or split per profile)
    - xserver-xorg-video-amdgpu        # AMD path; harmless if Intel
    - network-manager
    - qemu-guest-agent
    - git
    - curl
    - wget
  late-commands:
    - "curtin in-target --target=/target -- systemctl enable xrdp"
    - "curtin in-target --target=/target -- sh -c 'echo xfce4-session > /home/deskuser/.xsession && chmod +x /home/deskuser/.xsession && chown deskuser:deskuser /home/deskuser/.xsession'"
    - "curtin in-target --target=/target -- systemctl set-default graphical.target"
```

GNOME/grd profile: replace XFCE pkgs with `gnome gnome-remote-desktop
pipewire`, keep `xrdp xorgxrdp` as fallback, enable `grd.service` instead.
Select profile in `build-iso.sh` via `DESKTOP_PROFILE=xfce|xrdp|gnome`.

Notes:

* The passed-through iGPU appears as a real PCI device; no out-of-tree driver
  is baked. Firmware comes from the Ubuntu archive (`resolute main restricted
  universe multiverse`).
* RDP credential (`grdctl rdp set-credentials`) is **first-boot only** (§5),
  never in the image. xrdp path needs no baked secret.
* Guest firewall: allow `22`, `3389/tcp` on `vmbr0` only (`ufw default deny
  incoming`, `allow outgoing`).

## 5. First-boot guest turns (`first-boot.sh`, inside VM 100)

Seeded via `late-commands`/`cloud-init`, fetched at `<REF>`:

1. Assert passthrough: `lspci | grep -i vga` shows Intel/AMD iGPU;
   `glxinfo | grep 'OpenGL renderer'` shows the iGPU (not llvmpipe).
2. Default (XFCE/xrdp): `adduser xrdp ssl-cert`, ensure `.xsession`
   = `xfce4-session`, `systemctl enable --now xrdp`, disable compositing
   (`xfconf-query -c xfwm4 -p /general/use_compositing -s false`), low-memory
   trims (`cups/avahi/bluetooth` disable, `vm.swappiness=10`).
3. GNOME profile: `grdctl rdp enable` + `set-credentials` from a policy secret
   source (env/KV, never image), open `3389`; if no Wayland session, fall back
   to enabling `xrdp`/Xorg GDM. Probe `echo $XDG_SESSION_TYPE`.
4. Log to `/var/log/desktop-firstboot.log`; unit self-disables.

Connection: Windows `mstsc <VM_IP>:3389`; Linux
`xfreerdp /v:<VM_IP> /u:deskuser /dynamic-resolution`; macOS via MS RDP client.

## 6. Image build + cleanup

Build inside a throwaway builder (transient KVM/Proxmox scratch, no GPU) to
avoid builder residue:

1. Install from prepared ISO with the `user-data` docroot mounted.
2. Shut down, then `virt-sysprep` (libguestfs): remove SSH host keys,
   `/etc/machine-id`, logs, history; unset hostname/IP state (cloud-init
   regenerates); `zerofree` for compressible qcow2.
3. Output `output/desktop-golden.qcow2`; record SHA256 + `user-data` hash in
   `output/MANIFEST`.
4. Deliver to PVE storage/`payloads/` for `qm ... import-from` per Spec 01 §5.3.

Do not implement mimo FAI `package_config/DESKTOP`, `disk_config/DESKTOP`,
or `scripts/DESKTOP/*` — superseded.

## 7. Acceptance

* Unattended ISO boot → login screen, no prompts.
* `lspci`/`lshw` show the Intel/AMD VGA; board monitors light once `hostpci0`
  attached; `glxinfo` renderer is the iGPU.
* RDP from LAN reaches the session (XFCE default; Wayland/Xorg per profile).
* Golden contains no SSH host keys / machine-id / plaintext credential
  (`grep` audit over `/etc/ssh*`, `/var/lib/cloud*`).
* Rebuild from pinned ISO + `user-data` at same REF reproduces within the
  documented nondeterminism window (kernel/mesa pins recorded in MANIFEST).
