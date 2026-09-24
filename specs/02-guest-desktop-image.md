# Spec 02 — Guest: Desktop VM image (Ubuntu Desktop 26.04, iGPU owner)

Status: Draft (merged)
Pinned versions: Ubuntu Desktop **26.04 LTS (Resolute Raccoon)**, Proxmox VE **9.2**

## 1. Purpose and scope

Produce a golden QEMU disk (`desktop-golden.qcow2`) for Proxmox **vm 100**.
The VM owns the motherboard iGPU via VFIO, drives local board outputs where
attached, and serves the desktop over RDP on `:3389`.

The desktop's role is **display server + bastion** to the other guest VMs. It
runs a minimal window manager (i3-gaps), browsers, and SSH client. It does
**not** contain development tools — all dev work happens in dev VMs (Spec 04).

In scope: autoinstall `user-data`, ISO customization, first-boot RDP/session
wiring, i3 config, Chrome install, X11 forwarding setup. Out of scope:
host-side VFIO/VM wiring (Spec 01 §5), RDP access-control policy.

Supersedes `specs-mimo/vm-desktop.md` (XFCE-only, FAI-baked, user `ubuntu`,
30 GB) and `specs-ds4/02-guest-desktop-image.md` (GNOME/grd-only, 24.04,
user `popiel`, 60 GB). Default below is the i3-gaps path; GNOME/grd is
a retained profile.

## 2. Decisions

| Decision | Default |
|---|---|
| Base OS | Ubuntu Desktop **26.04 LTS** (official `ubuntu-26.04-desktop-amd64.iso`, SHA256 pinned in `build-iso.sh`) |
| Window manager | **i3-gaps + dmenu + i3status + i3blocks + picom** (lightweight, tiling, 32 GB friendly) |
| Display manager | **lightdm** (required for local console on passed-through iGPU) |
| Session (optional profile) | GNOME Wayland + `gnome-remote-desktop` primary, xrdp fallback (from ds4; use where HW-encode wanted) |
| RDP server | **xrdp + xorgxrdp** (unchanged from predecessor) |
| Terminal | **urxvt** (`rxvt-unicode`) |
| Browsers | **Firefox** (Ubuntu archive) + **Chrome** (snap, installed on first boot) |
| Audio | **PulseAudio + pavucontrol** |
| SSH | `openssh-client` (desktop → dev/LLM VMs) + `openssh-server` (LAN → desktop via host DNAT) |
| X11 forwarding | `xauth` + `sshd_config` `X11Forwarding yes` (desktop hosts X displays for dev VM apps) |
| Account | `popiel` (§05), SSH-key-only, autologin off |
| Disk | **40 GB** virtio system |
| Identity | NO machine-specific data (§6 cleanup) |
| Hostname | `lychee` (matches dnsmasq static DNS entry) |
| iGPU driver | **No special driver baked in.** Intel: `mesa`/`intel-media-va-driver` from archive; AMD APU: `xserver-xorg-video-amdgpu` + `mesa`. Installed via `packages:` / first-boot from official archive only |
| Excluded | `git`, file manager, text editor (vi in base), wallpaper tools — dev tools belong in dev VMs |

## 3. Build inputs

| File | Description |
|---|---|
| `ubuntu-26.04-desktop-amd64.iso` | Official, pinned + SHA256 in `build-iso.sh` |
| `desktop/user-data/meta-data` | Empty (NoCloud seed marker) |
| `desktop/user-data/user-data` | Autoinstall config (§4) |
| `desktop/build-iso.sh` | Injects `autoinstall` kernel args into ISO grub/isolinux AND/OR provisions HTTP `cidata` seed |
| `desktop/first-boot.sh` | i3 config, Chrome snap, X11 setup, fetched inside VM 100 on first boot at pinned `<REF>` |

Injection routes (same as ds4, versions bumped):

* Embedded: unpack ISO, append ` autoinstall ds=nocloud\;/cdrom/` to `linux`
  lines in `isolinux/txt.cfg` + `boot/grub/grub.cfg`, drop `user-data` at ISO
  root, repack (xorriso). Rebuild ISO per change.
* HTTP (recommended): boot stock ISO with
  `autoinstall ds=nocloud;s=http://<docroot>/desktop/`; keep `user-data` in
  docroot so edits don't rebuild the ISO.

## 4. `user-data` (representative, 26.04)

User identity values (`username`, `realname`) sourced from §05 via
`provision/personalization.sh`. The `build-iso.sh` script substitutes them
into the template at ISO build time.

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard: {layout: "us"}
  identity:
    hostname: lychee
    username: ${PERSONALIZATION_USERNAME}   # §05 via personalization.sh
    password: "CHANGE_ME_HASHED"   # prefer ssh-only
    realname: "${PERSONALIZATION_FULLNAME}"   # §05
  ssh:
    install-server: true
    allow-pw: false
  packages:
    # Window manager
    - i3
    - i3status
    - i3blocks
    - dmenu
    - picom
    - lightdm
    # Terminal
    - rxvt-unicode
    # RDP
    - xrdp
    - xorgxrdp
    # Browsers
    - firefox
    # X11 forwarding
    - xauth
    # SSH
    - openssh-client
    - openssh-server
    # Audio
    - pulseaudio
    - pavucontrol
    # Display
    - mesa-utils
    - intel-media-va-driver-non-free   # Intel path; harmless if AMD
    - xserver-xorg-video-amdgpu        # AMD path; harmless if Intel
    # System
    - network-manager
    - qemu-guest-agent
    - curl
    - wget
  late-commands:
    # Set UID/GID to 1401 (§05) — must run before any chown on this user
    - "curtin in-target --target=/target -- usermod -u 1401 ${PERSONALIZATION_USERNAME}"
    - "curtin in-target --target=/target -- groupmod -g 1401 ${PERSONALIZATION_USERNAME}"
    # Enable lightdm as display manager
    - "curtin in-target --target=/target -- systemctl enable lightdm"
    - "curtin in-target --target=/target -- systemctl set-default graphical.target"
    # Configure xrdp to launch i3
    - "curtin in-target --target=/target -- sh -c 'mkdir -p /home/${PERSONALIZATION_USERNAME}/.config && echo \"exec i3\" > /home/${PERSONALIZATION_USERNAME}/.xsession && chmod +x /home/${PERSONALIZATION_USERNAME}/.xsession && chown ${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME} /home/${PERSONALIZATION_USERNAME}/.xsession'"
    # Enable xrdp
    - "curtin in-target --target=/target -- systemctl enable xrdp"
    # Enable X11 forwarding in sshd
    - "curtin in-target --target=/target -- sed -i \"s/#X11Forwarding yes/X11Forwarding yes/\" /etc/ssh/sshd_config"
    # Set DNS to host dnsmasq (private network resolver)
    - "curtin in-target --target=/target -- sh -c 'echo \"[Network]\nDNS=192.168.100.1\" >> /etc/NetworkManager/conf.d/nested-dev.conf'"
```

GNOME/grd profile: replace i3/gaps pkgs with `gnome gnome-remote-desktop
pipewire`, keep `xrdp xorgxrdp` as fallback, enable `grd.service` instead.
Select profile in `build-iso.sh` via `DESKTOP_PROFILE=i3|gnome`.

Notes:

* The passed-through iGPU appears as a real PCI device; no out-of-tree driver
  is baked. Firmware comes from the Ubuntu archive (`resolute main restricted
  universe multiverse`).
* RDP credential (`grdctl rdp set-credentials`) is **first-boot only** (§5),
  never in the image. xrdp path needs no baked secret.
* Guest firewall: allow `22`, `3389/tcp` on `vmbr0` only (`ufw default deny
  incoming`, `allow outgoing`). Egress is unrestricted for the desktop VM;
  host iptables do not restrict desktop outbound.
* Chrome is **not** in the `packages:` list — installed via snap on first boot
  (§5) to avoid deb/snap conflicts during autoinstall.

## 5. First-boot guest turns (`first-boot.sh`, inside VM 100)

Seeded via `late-commands`/`cloud-init`, fetched at `<REF>`:

1. Assert passthrough: `lspci | grep -i vga` shows Intel/AMD iGPU;
   `glxinfo | grep 'OpenGL renderer'` shows the iGPU (not llvmpipe).
2. xrdp + i3: `adduser xrdp ssl-cert`, ensure `.xsession` = `exec i3`,
   `systemctl enable --now xrdp`.
3. i3 config: write `~/.config/i3/config` with defaults (Mod4=key,
   `bindsym $mod+Return exec urxvt`, `bindsym $mod+d exec dmenu_run`,
   bar with i3status, standard focus/resize/move binds). Write
   `~/.config/i3status/config` with network/disk/load/battery blocks.
4. picom: enable as i3 autostart (`exec picom`) for optional compositor.
5. Chrome: `snap install chromium`; write `~/.config/chromium-flags.conf`
   with `--disable-gpu` (avoids xrdp GPU conflicts).
6. PulseAudio: enable user service (`systemctl --user enable pulseaudio`).
7. SSH: confirm `X11Forwarding yes` in `/etc/ssh/sshd_config`; confirm
   `xauth` is installed. Desktop can now `ssh -X ${PERSONALIZATION_USERNAME}@<dev-vm>` to
   forward X11 apps from dev VMs.
8. Low-memory trims: disable `cups/avahi/bluetooth`, set `vm.swappiness=10`.
9. DNS: confirm NetworkManager uses `192.168.100.1` (host dnsmasq) for
   resolution of VM hostnames (`lychee-dev-*`, `lychee-llm`).
10. Log to `/var/log/desktop-firstboot.log`; unit self-disables.

Connection: Windows `mstsc <host-LAN-IP>:3389` (DNAT to desktop);
Linux `xfreerdp /v:<host-LAN-IP> /u:${PERSONALIZATION_USERNAME} /dynamic-resolution`;
macOS via MS RDP client. Alternatively, `ssh -J` through host or direct
SSH to `host-LAN-IP:22` (DNAT to desktop:22).

SSH from desktop to dev/LLM VMs:
```bash
ssh ${PERSONALIZATION_USERNAME}@lychee-dev-template      # by dnsmasq name
ssh -X ${PERSONALIZATION_USERNAME}@lychee-dev-template   # with X11 forwarding
ssh ${PERSONALIZATION_USERNAME}@lychee-llm                # LLM VM
```

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

* Unattended ISO boot → login screen (lightdm), no prompts.
* `lspci`/`lshw` show the Intel/AMD VGA; board monitors light once `hostpci0`
  attached; `glxinfo` renderer is the iGPU.
* i3 session starts (via lightdm or xrdp); `Mod4+Enter` opens urxvt;
  `Mod4+d` opens dmenu.
* RDP from LAN reaches the session; `firefox` and `chromium` (snap) launch.
* `ssh ${PERSONALIZATION_USERNAME}@lychee-dev-template` succeeds from desktop.
* `ssh -X ${PERSONALIZATION_USERNAME}@lychee-dev-template` forwards X11; `xclock` run on dev
  VM displays on desktop.
* `pactl info` shows PulseAudio running.
* Golden contains no SSH host keys / machine-id / plaintext credential
  (`grep` audit over `/etc/ssh*`, `/var/lib/cloud*`).
* Rebuild from pinned ISO + `user-data` at same REF reproduces within the
  documented nondeterminism window (kernel/mesa pins recorded in MANIFEST).
