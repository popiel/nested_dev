# Spec 02 — Guest: desktop (vm 100)

Status: Draft
Applies to: vm 100 `desktop`, hostname `lychee`
Pinned versions: Ubuntu Desktop **26.04 LTS**, Proxmox VE **9.2**
Implementation: `desktop/user-data/user-data`, `desktop/desktop-firstboot.sh`,
`desktop/devctl`

## 1. Scope

The desktop is the operator's window into the fleet and the bastion it
reaches the other guests through. It owns the motherboard iGPU, presents a
desktop over RDP, and hosts the control channel for dev VM lifecycle.

In scope: install seed content, first-boot configuration, window manager and
remote desktop, GPU passthrough verification, fleet-control installation,
guest firewall. Out of scope: host VFIO wiring (Spec 01), RDP access-control
policy on the LAN, dev VM lifecycle semantics (Spec 07), dev toolchain
(Spec 04).

Out of scope by design: **no development tooling is installed on the desktop.**
Toolchains on a machine that browses the internet defeat the point of
separating browsing from development.

## 2. Decisions

| Aspect | Choice |
|---|---|
| Base | Ubuntu Desktop 26.04 LTS, official ISO |
| Window manager | i3-gaps with dmenu, i3status, i3blocks, picom |
| Display manager | lightdm |
| Remote desktop | xrdp with xorgxrdp |
| Terminal | urxvt |
| Browsers | Firefox from the Ubuntu archive; Chrome as a snap, installed on first boot |
| Audio | PulseAudio with pavucontrol |
| iGPU driver | None baked in. The distro's own driver for the detected vendor, from the Ubuntu archive |
| Disk | 40 GB virtio |
| Session | Optional GNOME profile with `gnome-remote-desktop` is available where hardware encoding is wanted; i3 is the default |
| Identity | The account from Spec 05; guest `root` locked |
| Egress | Unrestricted (Spec 00 §R-00.2.6) |

## 3. Requirements

### R-02.1 Install

* **R-02.1.1** The desktop installs unattended from the official Ubuntu
  Desktop ISO with the host-assembled NoCloud seed (Spec 06). No image is
  built for it.
* **R-02.1.2** The seed installs the window manager, display manager, remote
  desktop, terminal, browser, audio, SSH client and server, X11 forwarding
  prerequisites and guest agent in one pass, so a boot that reaches a login
  screen is a boot with a complete desktop.
* **R-02.1.3** The account's UID and GID are set from the personalization
  configuration, and the seed sets them **before** any ownership operation on
  the account's files. A later `chown` against the pre-change UID leaves
  every file owned by a number that no longer resolves to a name.
* **R-02.1.4** lightdm is enabled as the display manager and the graphical
  target is the default. The iGPU's board outputs are the desktop's physical
  console; without lightdm there is no session on them.
* **R-02.1.5** SSH password authentication is disabled, and the seed trusts
  the operator key and the guest-identity key (Spec 06 §R-06.3).
* **R-02.1.6** The guest's resolver is the host's dnsmasq, not the LAN's. VM
  names resolve only there.
* **R-02.1.7** The hostname is fixed and matches the host's DNS entry for this
  VM.

### R-02.2 Session

* **R-02.2.1** An i3 session starts, both on the physical console through
  lightdm and over RDP — and it is the SAME session in both places
  (mirrored/cloned pixels), not an extended desktop and not a second
  session. The physical monitor is not visible from where the operator works,
  so a remote view showing anything else is operationally equivalent to no
  remote view. xorgxrdp alone creates separate sessions per login and does
  not satisfy this; the remote path must scrape the physical display
  (e.g. a VNC scrape of the console session gatewayed over RDP) or
  equivalent.
* **R-02.2.2** The session definition launches i3 explicitly, so an RDP session
  does not fall back to a bare X session with no window manager.
* **R-02.2.3** The account is added to the group that xrdp requires for
  certificate access; without it the session connects and then fails at
  authentication.
* **R-02.2.4** The window manager configuration is written on first boot with a
  working default binding set: a terminal launcher, a run-or-launch prompt,
  a status bar, and standard focus, move and resize bindings. A desktop that
  requires the operator to know the defaults is a desktop that gets
  reconfigured.
* **R-02.2.5** The compositor is started from the window manager session, not
  as a separate service.

### R-02.3 GPU passthrough is verified, and a software-rendered desktop is
reported

* **R-02.3.1** First boot checks that a real GPU is present and that the
  OpenGL renderer is that GPU rather than a software rasteriser.
* **R-02.3.2** A software renderer is **reported as a warning and does not
  abort the boot.** The desktop is the fleet's bastion; a guest that refuses
  to finish provisioning over a missing acceleration feature leaves the
  operator with no way to reach the guests at all.
* **R-02.3.3** A missing rendering tool is likewise reported, not fatal.
* **R-02.3.4** The iGPU drives the guest's physical console as its primary
  display, and the same desktop is reachable over RDP (R-02.2.1): a running
  guest with a black physical screen is a failure, not a headless success.
  Primary-mode passthrough on Intel integrated graphics is finicky (pre-boot
  hangs are the documented failure mode), so console output is verified on
  first boot rather than assumed from the `qm` flags.

### R-02.4 Browsers, audio and memory

* **R-02.4.1** Chrome is installed on first boot as a snap, not in the seed's
  package list. A snap and the archive's own browser packages conflict during
  an unattended install, and the failure mode is an install that does not
  complete.
* **R-02.4.2** Chrome is configured to disable GPU acceleration over RDP. The
  guest's GPU is passed through and used by the session; letting a sandboxed
  browser also drive it produces rendering artifacts in both.
* **R-02.4.3** Audio runs as a per-account service, with lingering enabled for
  the account so the service survives logout. Without lingering, audio stops
  when the RDP session ends and does not return.
* **R-02.4.4** Print, mDNS discovery and Bluetooth services are disabled and
  the VM's memory swappiness is lowered. The desktop is 8 GB of a 32 GB host
  shared with a GPU VM; a print spooler and a Bluetooth stack are memory the
  desktop does not need.
* **R-02.4.5** Media playback on the desktop has working sound. The integrated
  HD audio controller (00:1f.3) was the candidate, and it is disqualified:
  measured 2026-10-01 it shares IOMMU group 10 with the ISA bridge (00:1f.0),
  the memory controller (00:1f.2) and SMBus (00:1f.4), so passing it through
  would hand host-critical platform devices to the guest — the same rule
  that excluded the dGPUs (R-01.7), applied before any code was written.
  Sound therefore comes without audio passthrough: RDP audio redirection for
  remote sessions (R-02.4.3 keeps the per-account audio service alive across
  logouts for exactly this), and a USB audio device passed through by ID —
  which needs no IOMMU group — if the physical console needs its own output.

### R-02.5 X11 forwarding from dev VMs

* **R-02.5.1** The desktop can run an X application from a dev VM, forwarding
  the display over SSH.
* **R-02.5.2** X11 forwarding is enabled in the SSH server, and the X
  authentication tool is present. Forwarding without the authentication tool
  fails at the far end with a refusal the operator reads as a network problem.
* **R-02.5.3** The desktop's SSH configuration resolves fleet VMs by name, so
  the operator does not track addresses.

### R-02.6 Fleet control is installed and verified

* **R-02.6.1** `devctl` and the SSH host aliases are installed on first boot.
* **R-02.6.2** The two SSH aliases present **different privilege levels** and
  are distinct for that reason: one is a restricted, command-forced credential
  that can only operate the fleet, the other is a full host login. Combining
  them into one credential would give dev VM lifecycle control to anything
  holding it, including the key the desktop uses to reach guests.
* **R-02.6.3** First boot **hard-fails** if either seeded private key is
  missing or invalid, or if the authorised-keys entry is missing (Spec 06
  §R-06.3.4).
* **R-02.6.4** `devctl` takes the guest account name from the environment
  rather than embedding it, because it is not rendered through the
  personalization configuration and a hardcoded name would be a second
  identity literal (Spec 05 §R-05.1.1).
* **R-02.6.5** `devctl` refuses to run without a shell environment, rather than
  falling back to an empty account name and producing a confusing SSH failure.
* **R-02.6.6** The local binary directory is on the account's `PATH`.

### R-02.7 Guest firewall

* **R-02.7.1** Incoming traffic is denied by default. SSH and RDP are
  accepted, RDP from the host only.
* **R-02.7.2** Outgoing traffic is unrestricted by the guest firewall. The
  host's FORWARD chain is the authority for the desktop's egress
  (Spec 00 §R-00.2.6); the guest's own rules must not imply that they are.
* **R-02.7.3** Guest `root` is locked.

## 4. Invariants

* I-02.1 No development toolchain is installed on the desktop.
* I-02.2 No prebuilt desktop image exists; the desktop installs from official
  media.
* I-02.3 The desktop's SSH server refuses password authentication.
* I-02.4 The restricted and full-privilege host credentials are distinct.
* I-02.5 First boot either completes the fleet-control installation or fails
  loudly.

## 5. Acceptance

| # | Check |
|---|---|
| A-02.1 | The desktop installs unattended and reaches a lightdm login screen with no prompts. |
| A-02.2 | The account exists with the configured UID, GID, home, shell and full name, and `root` is locked. |
| A-02.3 | The iGPU appears as a real PCI device and the OpenGL renderer is the iGPU, not a software rasteriser. Removing the passthrough produces the warning and the boot still completes. |
| A-02.4 | A board monitor lights when the VM starts. |
| A-02.5 | An i3 session starts on the physical console and over RDP; the terminal launcher and run prompt work; the status bar renders. |
| A-02.6 | RDP from the LAN reaches the session. |
| A-02.7 | Firefox and Chrome both launch. Chrome runs with GPU acceleration disabled. |
| A-02.8 | `pactl` reports audio running, and audio survives an RDP logout and reconnect. |
| A-02.9 | Printing, mDNS and Bluetooth are inactive; swappiness is 10. |
| A-02.10 | `ssh` to the dev template by name succeeds, and `ssh -X` forwards a display: an X clock on the guest appears on the desktop. |
| A-02.11 | The hostname matches the host's DNS entry for this VM, and VM names resolve through the host's resolver. |
| A-02.12 | Both SSH host aliases exist with different privilege levels, and the restricted one cannot open a shell. |
| A-02.13 | Withholding either seeded private key fails the desktop's first boot with a named error. |
| A-02.14 | `devctl` contains no literal account name, and refuses to run with no `USER` set. |
| A-02.15 | The guest firewall denies unsolicited inbound, accepts SSH and RDP, and guest `root` is locked. |
| A-02.16 | No development toolchain is present. |

## 6. Cross-references

| Spec | Relationship |
|---|---|
| Spec 00 | Topology, memory profile, egress policy, sourcing and pinning |
| Spec 01 | iGPU passthrough, guest creation, host firewall |
| Spec 05 | Account identity, key injection, locked root |
| Spec 06 | Seed assembly and placeholder injection |
| Spec 07 | `devctl` verbs, credential matrix, host trust pin |
| Spec 09 | Seed and first-boot static checks |
