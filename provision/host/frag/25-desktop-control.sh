#!/usr/bin/env bash
# frag/25-desktop-control.sh — vmctl user, keypair, sudoers, inventory
# Runs between frag/20 (memory) and frag/30 (guest creation) in host first-boot.
# Creates the vmctl account and control keypair for desktop→host dev VM control.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

log "=== desktop-control setup ==="

# --- Inventory directory ---
mkdir -p /etc/nested-dev
if [ ! -f /etc/nested-dev/inventory ]; then
    cat > /etc/nested-dev/inventory <<'EOF'
# VMID  NAME  HOSTNAME  IP  MAC  STATUS  PROJECT
100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  running  desktop
101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  running  llm
102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template
EOF
    log "Inventory created at /etc/nested-dev/inventory"
else
    log "Inventory already exists"
fi

# --- vmctl user ---
if ! id vmctl >/dev/null 2>&1; then
    useradd -r -m -s /usr/sbin/nologin -d /home/vmctl vmctl 2>/dev/null \
        || useradd -r -M -s /usr/sbin/nologin vmctl  # fallback if -d fails
    log "vmctl user created"
else
    log "vmctl user already exists"
fi

# --- Generate control keypair ---
VMCTL_KEY_DIR="/root/.nested-dev/vmctl"
mkdir -p "$VMCTL_KEY_DIR"
if [ ! -f "${VMCTL_KEY_DIR}/vmctl_ed25519" ]; then
    ssh-keygen -t ed25519 -f "${VMCTL_KEY_DIR}/vmctl_ed25519" -N "" \
        -C "vmctl@nested-dev" 2>/dev/null
    chmod 600 "${VMCTL_KEY_DIR}/vmctl_ed25519"
    chmod 644 "${VMCTL_KEY_DIR}/vmctl_ed25519.pub"
    log "Control keypair generated"
else
    log "Control keypair already exists"
fi

# --- authorized_keys with ForceCommand restriction ---
mkdir -p /home/vmctl/.ssh
chmod 700 /home/vmctl/.ssh
PUB_KEY=$(cat "${VMCTL_KEY_DIR}/vmctl_ed25519.pub")
cat > /home/vmctl/.ssh/authorized_keys <<AUTH_EOF
command="/usr/local/sbin/vmctl-host",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ${PUB_KEY}
AUTH_EOF
chmod 600 /home/vmctl/.ssh/authorized_keys
chown -R vmctl:vmctl /home/vmctl/.ssh
log "authorized_keys written (ForceCommand → vmctl-host)"

# --- sudoers: only vmctl-host via root, no password ---
VMCTL_SUDOERS_SRC="/root/provision/vmctl/sudoers"
VMCTL_SUDOERS_DST="/etc/sudoers.d/vmctl"
if [ -f "$VMCTL_SUDOERS_SRC" ]; then
    cp "$VMCTL_SUDOERS_SRC" "$VMCTL_SUDOERS_DST"
else
    cat > "$VMCTL_SUDOERS_DST" <<'SUDOERS_EOF'
vmctl ALL=(root) NOPASSWD: /usr/local/sbin/vmctl-host
SUDOERS_EOF
fi
chmod 440 "$VMCTL_SUDOERS_DST"
log "sudoers drop-in written"

# --- Copy vmctl-host script ---
VMCTL_HOST_SRC="/root/provision/vmctl/vmctl-host"
VMCTL_HOST_DST="/usr/local/sbin/vmctl-host"
if [ -f "$VMCTL_HOST_SRC" ]; then
    cp "$VMCTL_HOST_SRC" "$VMCTL_HOST_DST"
    chmod 755 "$VMCTL_HOST_DST"
    log "vmctl-host installed"
else
    log "WARNING: vmctl-host source not found at ${VMCTL_HOST_SRC}"
fi

# --- Staging path for frag/30 (desktop seed injection) ---
STAGED_KEY="/root/.nested-dev/vmctl-priv-staged"
cp "${VMCTL_KEY_DIR}/vmctl_ed25519" "$STAGED_KEY"
chmod 600 "$STAGED_KEY"
log "Private key staged for desktop seed injection"

# --- dnsmasq dev drop-in (empty header; vmctl-host appends entries) ---
if [ ! -f /etc/dnsmasq.d/zz-dev.conf ]; then
    echo "# Per-project dev VMs — added by vmctl-host on demand" > /etc/dnsmasq.d/zz-dev.conf
    log "dnsmasq dev drop-in created"
fi

log "=== desktop-control setup complete ==="
