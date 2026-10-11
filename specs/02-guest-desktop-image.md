# Spec 02 — Guest: desktop (vm 100)

Status: Draft
Applies to: vm 100 `desktop`, hostname `lychee`
Pinned versions: Ubuntu Desktop **26.04 LTS**, Proxmox VE **9.2**
Implementation: `desktop/user-data/user-data`, `desktop/desktop-firstboot.sh`,
`desktop/devctl`

## 1. Scope

The desktop is the operator's window into the fleet and the bastion it
reaches the other guests through. It owns the motherboard iGPU, presents a
desktop over the VNC console mirror, and hosts the control channel for dev VM lifecycle.

In scope: install seed content, first-boot configuration, window manager and
remote console mirror, GPU passthrough verification, fleet-control installation,
guest firewall. Out of scope: host VFIO wiring (Spec 01), dev VM lifecycle semantics (Spec 07), dev toolchain
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
| Remote console | x11vnc VNC mirror of the physical console (same pixels, verified live) |
| Physical input | Rack keyboard/mouse shared by evdev passthrough with ctrl-ctrl grab-toggle (R-02.2.7) |
| Terminal | urxvt |
| Browsers | Firefox from the Ubuntu archive; Chrome as a snap, installed on first boot |
| Audio | PulseAudio with pavucontrol |
| iGPU driver | None baked in. The distro's own driver for the detected vendor, from the Ubuntu archive |
| Disk | 40 GB virtio |
| Session | i3 only. The GNOME/Wayland session is diverted out of the chooser: LightDM cannot host it, and a login into it kills the console (R-02.2.4). |
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
* **R-02.1.4** The desktop reaches a graphical login on the physical console
  by default. The iGPU's board outputs are the desktop's physical console;
  without a display manager there is no session on them.
  Current mechanism: lightdm enabled with the graphical target as default.
* **R-02.1.5** SSH password authentication is disabled, and the seed trusts
  the operator key and the guest-identity key (Spec 06 §R-06.3).
* **R-02.1.6** The guest's resolver is the host's dnsmasq, not the LAN's. VM
  names resolve only there. Bare names resolve via the `wolfskeep.com`
  search domain (Spec 01 §R-01.9.2).
* **R-02.1.7** The hostname is fixed and matches the host's DNS entry for this
  VM.

### R-02.2 Session

* **R-02.2.1** A session starts on the physical console, and the remote path shows the SAME session (mirrored/cloned
  pixels), not an extended desktop and not a second session. The physical
  monitor is not visible from where the operator works, so a remote view
  showing anything else is operationally equivalent to no remote view.
  Separate-sessions-per-login remote stacks can never satisfy this
  requirement, so none is installed, forwarded, or admitted by the guest
  firewall. Current mechanism: i3 via lightdm mirrored with x11vnc,
  verified live pixel-for-pixel with working input; no RDP/xrdp.
* **R-02.2.2** The window manager configuration is written on first boot with a
  working default binding set: a terminal launcher, a run-or-launch prompt,
  a status bar, and standard focus, move and resize bindings. A desktop that
  requires the operator to know the defaults is a desktop that gets
  reconfigured.
* **R-02.2.3** The compositor runs inside the window manager session, so it
  shares the session lifecycle instead of racing it as an independent unit.
  Current mechanism: started from the WM session, not as a separate service.
* **R-02.2.4** Logging in always lands in a working console session — never
  in a displayless session that kills the physical console and starves the
  VNC mirror of a framebuffer. Belt and suspenders: the default is pinned
  *and* incompatible session files are hidden from the greeter, since the
  greeter enumerates sessions on its own (observed live).
  Current mechanism: default session i3 set at install; Wayland session file
  diverted (LightDM cannot host Wayland).
* **R-02.2.5** The console stack remains the validated one until an incident
  forces re-evaluation with full session/mirror/input/auth/shutdown
  re-validation. Revisit on a second shutdown-hang-class mirror incident, or
  on a concrete need the current stack cannot meet (per-output capture,
  encrypted VNC). Current mechanism: X11 stack (lightdm, Xorg, x11vnc);
  Wayland move (Sway + wayvnc/w0vncserver + native replacements for
  dmenu/urxvt/picom) evaluated and deferred.
* **R-02.2.6** Every keystroke (including held keys and BackSpace) is
  delivered exactly once, with repeat owned in exactly one place and toggled
  by the operator, never automated. A second repeating layer doubles every
  character; host-kernel repeats on top of guest-side repeats arrive as extra
  presses. Current mechanism: server-owned repeat re-enabled with `xset r on`
  as needed (x11vnc reapplies off per connection), non-repeating viewer,
  evdev `repeat=off`.
* **R-02.2.7** The physical rack keyboard and mouse are usable in the guest
  and returnable to the host by an operator toggle, without stranding host
  repair and without GPU changes (iGPU stays with the desktop, dGPUs with
  101). While toggled to the guest the host console is keyboardless
  (accepted: host display is already gone and SSH is unaffected).
  Current mechanism: evdev passthrough (`input-linux` on stable by-id paths
  detected at provision, virtio-keyboard + relative virtio-mouse),
  ctrl-ctrl (both Ctrls together) toggle; static USB attachment and
  X-state-conditional routing rejected by decision.

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
  display, and the same desktop is reachable over the VNC mirror (R-02.2.1): a running
  guest with a black physical screen is a failure, not a headless success.
  Primary-mode passthrough on Intel integrated graphics is finicky (pre-boot
  hangs are the documented failure mode), so console output is verified on
  first boot rather than assumed from the `qm` flags.

### R-02.4 Browsers, audio and memory

* **R-02.4.1** Both browsers are installable and the desktop install always
  completes. Current mechanism: Chrome as a first-boot snap, not in the
  seed package list (snap + archive browser packages conflict mid-install).
* **R-02.4.2** Browser and session rendering do not corrupt each other on the
  passed-through GPU. Current mechanism: Chrome configured with GPU
  acceleration disabled.
* **R-02.4.3** Audio keeps working across logout and login. Current
  mechanism: per-account audio service with lingering enabled.
* **R-02.4.4** Unneeded device services stay off and the desktop stays within
  its 8 GB share of the 32 GB host. Current mechanism: print, mDNS discovery
  and Bluetooth disabled; swappiness lowered to 10.
* **R-02.4.5** Media playback on the desktop has working sound without
  handing host-critical platform devices to the guest. The integrated HD
  audio candidate shares its IOMMU group with the ISA bridge, memory
  controller and SMBus (measured 2026-10-01), so it is disqualified under
  R-01.7. Current mechanism: USB audio device passed through by ID for the
  physical console; VNC mirror carries no audio.

### R-02.5 X11 forwarding from dev VMs

* **R-02.5.1** The desktop can run an X application from a dev VM, forwarding
  the display over SSH.
* **R-02.5.2** Forwarded X applications authenticate and display on the
  desktop instead of failing with a far-end refusal that reads as a network
  problem. Current mechanism: X11 forwarding enabled in the SSH server with
  the X authentication tool present.
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
  missing or invalid, if the authorised-keys entry is missing (Spec 06
  §R-06.3.4), or if the `devctl` source is absent from beside the first-boot
  script. A desktop without fleet control is not a completed desktop, and
  the previous warn-and-continue shipped exactly that, green.
* **R-02.6.4** `devctl` resolves the guest account without a second hardcoded
  identity literal (Spec 05 §R-05.1.1). Current mechanism: account name from
  the environment.
* **R-02.6.5** `devctl` fails fast with a named cause when its account context
  is missing, rather than producing a confusing downstream SSH failure.
  Current mechanism: refuses to run without a shell environment instead of
  falling back to an empty account name.
* **R-02.6.6** The fleet-control command is invocable without a path prefix.
  Current mechanism: local binary directory on the account's `PATH`.

### R-02.7 Guest firewall

* **R-02.7.1** Incoming traffic is denied by default. SSH is accepted, and
  the VNC console mirror is accepted from the LAN.
* **R-02.7.2** Outgoing traffic is unrestricted by the guest firewall. The
  host's FORWARD chain is the authority for the desktop's egress
  (Spec 00 §R-00.2.6); the guest's own rules must not imply that they are.
* **R-02.7.3** Guest `root` is locked per Spec 05 §R-05.5.

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
| A-02.5 | An i3 session starts on the physical console; the VNC mirror shows the same pixels, the terminal launcher and run prompt work, and the status bar renders. |
| A-02.6 | VNC from the LAN reaches the mirrored session with working input. |
| A-02.7 | Firefox and Chrome both launch. Chrome runs with GPU acceleration disabled. |
| A-02.8 | `pactl` reports audio running, and audio survives a logout and login. |
| A-02.9 | Printing, mDNS and Bluetooth are inactive; swappiness is 10. |
| A-02.10 | `ssh` to the dev template by name succeeds, and `ssh -X` forwards a display: an X clock on the guest appears on the desktop. |
| A-02.11 | The hostname matches the host's DNS entry for this VM, and VM names resolve through the host's resolver. |
| A-02.12 | Both SSH host aliases exist with different privilege levels, and the restricted one cannot open a shell. |
| A-02.13 | Withholding either seeded private key fails the desktop's first boot with a named error. |
| A-02.14 | `devctl` contains no literal account name, and refuses to run with no `USER` set. |
| A-02.15 | The guest firewall denies unsolicited inbound, accepts SSH and the VNC mirror from the LAN, and guest `root` is locked. |
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
