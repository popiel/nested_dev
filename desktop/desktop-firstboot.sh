#!/usr/bin/env bash
# desktop-firstboot.sh — Desktop VM first-boot configuration
# Runs inside VM 100 (lychee / ${PERSONALIZATION_USERNAME}) on first boot.
# Sets up i3, xrdp, Chrome, X11 forwarding, PulseAudio, low-mem trims.
# Fetched at REF main; logs to /var/log/desktop-firstboot.log.
set -euo pipefail

LOG="/var/log/desktop-firstboot.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

# --- Source shared personalization (§05) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# When fetched from GitHub at REF, personalization.sh is alongside this script
if [ -f "${SCRIPT_DIR}/personalization.sh" ]; then
    . "${SCRIPT_DIR}/personalization.sh"
else
    # Fallback: hardcoded values (must match provision/personalization.sh)
    PERSONALIZATION_USERNAME="popiel"
    PERSONALIZATION_FULLNAME="T. Alexander Popiel"
    PERSONALIZATION_EMAIL="tapopiel@gmail.com"
    PERSONALIZATION_UID="1401"
    PERSONALIZATION_GID="1401"
    PERSONALIZATION_HOME="/home/${PERSONALIZATION_USERNAME}"
fi

log "=== desktop first-boot starting ==="

# --- 1. Assert GPU passthrough (informational, non-fatal) ---
if command -v glxinfo >/dev/null 2>&1; then
    GPU_RENDERER=$(glxinfo 2>/dev/null | grep 'OpenGL renderer' | awk -F': ' '{print $2}' || echo "unknown")
    log "GPU renderer: ${GPU_RENDERER}"
    if echo "$GPU_RENDERER" | grep -qi "llvmpipe\|softpipe"; then
        log "WARNING: Software rendering detected — iGPU passthrough may not be active"
    fi
else
    log "glxinfo not available — skipping GPU assertion"
fi

# --- 2. xrdp + i3 session ---
log "Configuring xrdp and i3 session"
adduser xrdp ssl-cert 2>/dev/null || true

# Ensure .xsession launches i3
DESKUSER_HOME=$(getent passwd "${PERSONALIZATION_USERNAME}" | cut -d: -f6)
mkdir -p "${DESKUSER_HOME}/.config"
cat > "${DESKUSER_HOME}/.xsession" <<'XSESSION_EOF'
exec i3
XSESSION_EOF
chmod +x "${DESKUSER_HOME}/.xsession"
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${DESKUSER_HOME}/.xsession"

systemctl enable --now xrdp
log "xrdp enabled, .xsession set to i3"

# --- 3. i3 config ---
log "Writing i3 config"
mkdir -p "${DESKUSER_HOME}/.config/i3"
cat > "${DESKUSER_HOME}/.config/i3/config" <<'I3_EOF'
# i3 config for nested_dev desktop (lychee)
set $mod Mod4

# Terminal
bindsym $mod+Return exec urxvt

# Application launcher
bindsym $mod+d exec dmenu_run

# Kill focused window
bindsym $mod+Shift+q kill

# Change focus (vim keys)
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move focused window (vim keys)
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Split orientation
bindsym $mod+b split h
bindsym $mod+v split v

# Fullscreen
bindsym $mod+f fullscreen toggle

# Layouts
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split

# Toggle tiling/floating
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle

# Focus parent/child
bindsym $mod+a focus parent

# Workspaces
set $ws1 "1"
set $ws2 "2"
set $ws3 "3"
set $ws4 "4"
set $ws5 "5"
set $ws6 "6"
set $ws7 "7"
set $ws8 "8"
set $ws9 "9"
set $ws10 "10"

bindsym $mod+1 workspace number $ws1
bindsym $mod+2 workspace number $ws2
bindsym $mod+3 workspace number $ws3
bindsym $mod+4 workspace number $ws4
bindsym $mod+5 workspace number $ws5
bindsym $mod+6 workspace number $ws6
bindsym $mod+7 workspace number $ws7
bindsym $mod+8 workspace number $ws8
bindsym $mod+9 workspace number $ws9
bindsym $mod+0 workspace number $ws10

bindsym $mod+Shift+1 move container to workspace number $ws1
bindsym $mod+Shift+2 move container to workspace number $ws2
bindsym $mod+Shift+3 move container to workspace number $ws3
bindsym $mod+Shift+4 move container to workspace number $ws4
bindsym $mod+Shift+5 move container to workspace number $ws5
bindsym $mod+Shift+6 move container to workspace number $ws6
bindsym $mod+Shift+7 move container to workspace number $ws7
bindsym $mod+Shift+8 move container to workspace number $ws8
bindsym $mod+Shift+9 move container to workspace number $ws9
bindsym $mod+Shift+0 move container to workspace number $ws10

# Reload / restart
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart

# Resize mode
mode "resize" {
    bindsym h resize shrink width 10 px or 10 ppt
    bindsym j resize grow height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow width 10 px or 10 ppt

    bindsym Return mode "default"
    bindsym Escape mode "default"
    bindsym $mod+r mode "default"
}
bindsym $mod+r mode "resize"

# i3bar with i3status
bar {
    status_command i3status
    position top
}

# Compositor (picom)
exec --no-startup-id picom

# Audio volume keys (PulseAudio)
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute exec pactl set-sink-mute @DEFAULT_SINK@ toggle
I3_EOF
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${DESKUSER_HOME}/.config/i3/config"
log "i3 config written"

# --- 4. i3status config ---
log "Writing i3status config"
mkdir -p "${DESKUSER_HOME}/.config/i3status"
cat > "${DESKUSER_HOME}/.config/i3status/config" <<'I3STATUS_EOF'
general {
    output_format = "i3bar"
    colors = true
    interval = 5
}

order += "disk /"
order += "disk /home"
order += "memory"
order += "cpu_usage"
order += "net_all"
order += "tztime local"

disk "/" {
    format = "%avail"
}

disk "/home" {
    format = "%avail"
}

memory {
    format = "%used / %total"
    threshold_degraded = "1G"
    threshold_critical = "200M"
}

cpu_usage {
    format = "%usage"
}

net_all {
    format_down = "No IP"
}

tztime local {
    format = "%Y-%m-%d %H:%M:%S"
}
I3STATUS_EOF
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${DESKUSER_HOME}/.config/i3status/config"
log "i3status config written"

# --- 5. Chrome (snap) ---
log "Installing Chrome via snap"
if ! command -v chromium >/dev/null 2>&1; then
    snap install chromium 2>&1 | tee -a "$LOG" || log "WARNING: Chrome snap install failed"
fi

# Disable GPU in Chrome (avoids xrdp GPU conflicts)
cat > "${DESKUSER_HOME}/.config/chromium-flags.conf" <<'CHROME_EOF'
--disable-gpu
--no-sandbox
CHROME_EOF
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${DESKUSER_HOME}/.config/chromium-flags.conf"
log "Chrome flags configured (--disable-gpu)"

# --- 6. PulseAudio ---
log "Enabling PulseAudio"
# Enable for ${PERSONALIZATION_USERNAME} at login (PAM linger)
loginctl enable-linger "${PERSONALIZATION_USERNAME}" 2>/dev/null || true
sudo -u "${PERSONALIZATION_USERNAME}" systemctl --user enable pulseaudio 2>/dev/null || true
log "PulseAudio enabled"

# --- 7. SSH X11 forwarding ---
log "Verifying SSH X11 forwarding"
if grep -q "^#X11Forwarding yes" /etc/ssh/sshd_config; then
    sed -i 's/^#X11Forwarding yes/X11Forwarding yes/' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || true
    log "X11Forwarding enabled in sshd_config"
elif grep -q "^X11Forwarding yes" /etc/ssh/sshd_config; then
    log "X11Forwarding already enabled"
else
    echo "X11Forwarding yes" >> /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || true
    log "X11Forwarding added to sshd_config"
fi

# Verify xauth is installed
if ! dpkg -l xauth 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    apt-get install -y xauth
    log "xauth installed"
fi

# --- 8. Low-memory trims ---
log "Applying low-memory trims"
systemctl disable --now cups 2>/dev/null || true
systemctl disable --now avahi-daemon 2>/dev/null || true
systemctl disable --now bluetooth 2>/dev/null || true

# Lower swappiness
echo 'vm.swappiness=10' > /etc/sysctl.d/99-desktop-swappiness.conf
sysctl -w vm.swappiness=10 2>/dev/null || true
log "Low-memory trims applied (cups/avahi/bluetooth disabled, swappiness=10)"

# --- 9. DNS verification ---
log "Verifying DNS configuration"
if [ -f /etc/NetworkManager/conf.d/nested-dev.conf ]; then
    log "NetworkManager DNS config present: $(cat /etc/NetworkManager/conf.d/nested-dev.conf)"
else
    log "WARNING: nested-dev DNS config missing — VM hostnames may not resolve"
fi

# --- 10. Hostname ---
hostnamectl set-hostname lychee
log "Hostname set to lychee"

# --- 11. Dev fleet control (devctl + SSH config) ---
log "Installing devctl and SSH config for vmctl"
BIN_DIR="${DESKUSER_HOME}/.local/bin"
mkdir -p "$BIN_DIR"

# Copy devctl script
DEVCTL_SRC="${SCRIPT_DIR}/devctl"
if [ -f "$DEVCTL_SRC" ]; then
    cp "$DEVCTL_SRC" "${BIN_DIR}/devctl"
    chmod +x "${BIN_DIR}/devctl"
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${BIN_DIR}/devctl"
    log "devctl installed to ${BIN_DIR}/devctl"
else
    log "WARNING: devctl source not found at ${DEVCTL_SRC}"
fi

# SSH config for pvehost (vmctl user)
mkdir -p "${DESKUSER_HOME}/.ssh"
cat > "${DESKUSER_HOME}/.ssh/config" <<'SSH_CONFIG_EOF'
Host pvehost
    HostName 192.168.100.1
    User vmctl
    IdentityFile ~/.ssh/pvehost_vmctl
    StrictHostKeyChecking accept-new
    IdentitiesOnly yes
SSH_CONFIG_EOF
chmod 600 "${DESKUSER_HOME}/.ssh/config"
chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "${DESKUSER_HOME}/.ssh/config"

# Add ~/.local/bin to PATH if not already there
BASHRC="${DESKUSER_HOME}/.bashrc"
if ! grep -q '.local/bin' "$BASHRC" 2>/dev/null; then
    echo '' >> "$BASHRC"
    echo '# Dev tool wrappers (§05)' >> "$BASHRC"
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "$BASHRC"
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "$BASHRC"
    log "Added ~/.local/bin to PATH in .bashrc"
fi

# Fix permissions on vmctl key if it was injected via seed
VMCTL_KEY="${DESKUSER_HOME}/.ssh/pvehost_vmctl"
if [ -f "$VMCTL_KEY" ]; then
    chmod 600 "$VMCTL_KEY"
    chown "${PERSONALIZATION_USERNAME}:${PERSONALIZATION_USERNAME}" "$VMCTL_KEY"
    log "vmctl key permissions set"
fi

# --- Self-disable ---
log "=== desktop first-boot complete — disabling unit ==="
systemctl disable --now desktop-firstboot 2>/dev/null || true

log "=== done ==="
