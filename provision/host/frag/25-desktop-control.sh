#!/usr/bin/env bash
# frag/25-desktop-control.sh — vmctl user, keypair, sudoers, inventory
# Runs between frag/20 (memory) and frag/30 (guest creation) in host first-boot.
# Creates the vmctl account and control keypair for desktop→host dev VM control.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }
die() { log "FATAL: $*"; exit 1; }

log "=== desktop-control setup ==="

# --- Inventory directory ---
mkdir -p "${ROOT}/etc/nested-dev"
if [ ! -f "${ROOT}/etc/nested-dev/inventory" ]; then
    cat > "${ROOT}/etc/nested-dev/inventory" <<'EOF'
# VMID  NAME  HOSTNAME  IP  MAC  STATUS  PROJECT
100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  running  desktop
101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  running  llm
102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template
EOF
    log "Inventory created at ${ROOT}/etc/nested-dev/inventory"
else
    log "Inventory already exists"
fi

# --- vmctl user ---
# The login shell MUST be a real shell. sshd_config(5) states that ForceCommand
# "is invoked by using the user's login shell with the -c option", so with
# /usr/sbin/nologin sshd would run
#   /usr/sbin/nologin -c "/usr/local/sbin/vmctl-host <verb>"
# and nologin would print "This account is currently not available" and exit 1
# without ever running vmctl-host. Restriction comes from the forced command in
# authorized_keys, not from the shell; the account password stays locked
# (useradd -r), so this remains key-only.
VMCTL_SHELL="/bin/bash"
if ! id vmctl >/dev/null 2>&1; then
    useradd -r -m -s "$VMCTL_SHELL" -d /home/vmctl vmctl 2>/dev/null \
        || useradd -r -M -s "$VMCTL_SHELL" vmctl  # fallback if -d fails
    log "vmctl user created (shell=${VMCTL_SHELL})"
else
    # Correct the shell if an earlier run created it with nologin.
    current_shell=$(getent passwd vmctl | cut -d: -f7)
    if [ "$current_shell" != "$VMCTL_SHELL" ]; then
        usermod -s "$VMCTL_SHELL" vmctl
        log "vmctl shell corrected: ${current_shell} -> ${VMCTL_SHELL}"
    else
        log "vmctl user already exists (shell=${VMCTL_SHELL})"
    fi
fi

# --- Generate control keypair ---
VMCTL_KEY_DIR="${ROOT}/root/.nested-dev/vmctl"
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
mkdir -p "${ROOT}/home/vmctl/.ssh"
chmod 700 "${ROOT}/home/vmctl/.ssh"
PUB_KEY=$(cat "${VMCTL_KEY_DIR}/vmctl_ed25519.pub")
cat > "${ROOT}/home/vmctl/.ssh/authorized_keys" <<AUTH_EOF
command="/usr/local/sbin/vmctl-host",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ${PUB_KEY}
AUTH_EOF
chmod 600 "${ROOT}/home/vmctl/.ssh/authorized_keys"
chown -R vmctl:vmctl "${ROOT}/home/vmctl/.ssh"
log "authorized_keys written (ForceCommand → vmctl-host)"

# --- sudoers: only vmctl-host via root, no password ---
# provision/host/vmctl/ in the repo becomes /root/provision/host/vmctl/ on the
# host: first-boot.sh extracts the archive's provision/ directory to
# /root/provision. Resolving the source relative to this script keeps the
# fragment correct wherever the tree lives, and means a missing vmctl-host is a
# hard failure instead of a warning that leaves the whole devctl control
# channel pointing at a binary that was never installed.
VMCTL_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../vmctl" && pwd)"
VMCTL_SUDOERS_SRC="${VMCTL_SRC_DIR}/sudoers"
VMCTL_SUDOERS_DST="${ROOT}/etc/sudoers.d/vmctl"
mkdir -p "$(dirname "$VMCTL_SUDOERS_DST")"
if [ -f "$VMCTL_SUDOERS_SRC" ]; then
    install -m 440 "$VMCTL_SUDOERS_SRC" "$VMCTL_SUDOERS_DST"
else
    # install(1) rather than cp + chmod: it creates the destination fresh, so a
    # re-run over the existing mode-440 file does not fail trying to truncate a
    # file it cannot write.
    install -m 440 /dev/stdin "$VMCTL_SUDOERS_DST" <<'SUDOERS_EOF'
vmctl ALL=(root) NOPASSWD: /usr/local/sbin/vmctl-host
SUDOERS_EOF
fi
log "sudoers drop-in written"

# --- Copy vmctl-host script ---
VMCTL_HOST_SRC="${VMCTL_SRC_DIR}/vmctl-host"
VMCTL_HOST_DST="${ROOT}/usr/local/sbin/vmctl-host"
mkdir -p "$(dirname "$VMCTL_HOST_DST")"
if [ -f "$VMCTL_HOST_SRC" ]; then
    cp "$VMCTL_HOST_SRC" "$VMCTL_HOST_DST"
    chmod 755 "$VMCTL_HOST_DST"
    log "vmctl-host installed"
else
    die "vmctl-host source not found at ${VMCTL_HOST_SRC} — the desktop's
devctl fleet verbs (list/status/start/stop/kill/add/log) would all fail
against a forced command that does not exist"
fi

# --- Staging path for frag/30 (desktop seed injection) ---
STAGED_KEY="${ROOT}/root/.nested-dev/vmctl-priv-staged"
cp "${VMCTL_KEY_DIR}/vmctl_ed25519" "$STAGED_KEY"
chmod 600 "$STAGED_KEY"
log "Private key staged for desktop seed injection"

# --- Guest identity keypair ---
# Generated on the host at install time. The PRIVATE half is the desktop
# guest's identity and is seeded to the desktop only; the PUBLIC half is
# trusted by the host OS and by every guest, so the desktop can administer the
# whole deployment. Distinct from vmctl, which is a restricted forced-command
# credential with no shell access.
GUEST_ID_KEY_DIR="${ROOT}/root/.nested-dev/guest-id"
DESKTOP_IP="192.168.100.100"
mkdir -p "$GUEST_ID_KEY_DIR"
if [ ! -f "${GUEST_ID_KEY_DIR}/guest_id_ed25519" ]; then
    ssh-keygen -t ed25519 -f "${GUEST_ID_KEY_DIR}/guest_id_ed25519" -N "" \
        -C "guest-id@$(hostname -s)" 2>/dev/null
    chmod 600 "${GUEST_ID_KEY_DIR}/guest_id_ed25519"
    chmod 644 "${GUEST_ID_KEY_DIR}/guest_id_ed25519.pub"
    log "Guest identity keypair generated"
else
    log "Guest identity keypair already exists"
fi

# Trust the guest identity key on the host. Pinned to the desktop's static
# address (issued as a dnsmasq dhcp-host lease for MAC 52:54:00:00:01:00 in
# provision/network/dnsmasq.conf and frag/90-finalize.sh) so that a leaked copy
# of the key is only usable from the desktop VM. The forwarding options match
# the vmctl entry. tests/e2e/provision.bats asserts the pin lands in
# root's authorized_keys — if the desktop address ever changes, update both or
# host access from the desktop silently breaks while the key is still present.
GUEST_ID_PUB=$(cat "${GUEST_ID_KEY_DIR}/guest_id_ed25519.pub")
ROOT_AUTH_KEYS="${ROOT}/root/.ssh/authorized_keys"
CLUSTER_AUTH_KEYS="${ROOT}/etc/pve/priv/authorized_keys"
mkdir -p "${ROOT}/root/.ssh"
chmod 700 "${ROOT}/root/.ssh"
# A real file, never PVE's symlink into pmxcfs. When pve-cluster is down the
# link dangles: root loses key auth entirely (sshd reads zero keys through
# it) and even touching the path fails with ENOENT — exactly when access
# matters most. Convert once, preserving whatever the link resolves to, then
# merge the cluster store on every run so keys added cluster-side are never
# lost. Local extras are never removed: revoking a key means editing the real
# file, not the cluster store.
if [ -L "$ROOT_AUTH_KEYS" ]; then
    LINK_CONTENT="$(cat "$ROOT_AUTH_KEYS" 2>/dev/null || true)"
    rm -f "$ROOT_AUTH_KEYS"
    if [ -n "$LINK_CONTENT" ]; then
        printf '%s\n' "$LINK_CONTENT" > "$ROOT_AUTH_KEYS"
    fi
    log "replaced authorized_keys symlink with a real file (degraded-mode SSH)"
fi
if [ -r "$CLUSTER_AUTH_KEYS" ]; then
    while IFS= read -r keyline || [ -n "$keyline" ]; do
        [ -n "$keyline" ] || continue
        grep -qF -- "$keyline" "$ROOT_AUTH_KEYS" 2>/dev/null \
            || printf '%s\n' "$keyline" >> "$ROOT_AUTH_KEYS"
    done < "$CLUSTER_AUTH_KEYS"
    log "merged cluster authorized_keys"
fi
touch "$ROOT_AUTH_KEYS"
chmod 600 "$ROOT_AUTH_KEYS"
# grep on the key body only, so re-running does not append a duplicate entry.
if grep -qF "$GUEST_ID_PUB" "$ROOT_AUTH_KEYS"; then
    log "Guest identity key already trusted on host"
else
    printf 'from="%s",no-agent-forwarding,no-port-forwarding,no-X11-forwarding %s\n' \
        "$DESKTOP_IP" "$GUEST_ID_PUB" >> "$ROOT_AUTH_KEYS"
    log "Guest identity key trusted on host (pinned to ${DESKTOP_IP})"
fi

# Stage the guest identity private half for frag/30 (desktop seed injection).
# Re-staged on every run; frag/30 shreds it once the seeds are built.
GUEST_ID_STAGED="${ROOT}/root/.nested-dev/guest-id-priv-staged"
cp "${GUEST_ID_KEY_DIR}/guest_id_ed25519" "$GUEST_ID_STAGED"
chmod 600 "$GUEST_ID_STAGED"
log "Guest identity private key staged for desktop seed injection"

# --- dnsmasq dev drop-in (empty header; vmctl-host appends entries) ---
if [ ! -f "${ROOT}/etc/dnsmasq.d/zz-dev.conf" ]; then
    mkdir -p "${ROOT}/etc/dnsmasq.d"
    echo "# Per-project dev VMs — added by vmctl-host on demand" > "${ROOT}/etc/dnsmasq.d/zz-dev.conf"
    log "dnsmasq dev drop-in created"
fi

# --- sshd on 2222 for LAN management, keeping 22 for the desktop ---
# The documented path is ssh -p 2222 root@<LAN-IP>, admitted by frag/90 from
# the LAN while port 22 stays desktop-only. sshd serves it by listening on
# 2222 directly (a DNAT 2222→host:22 cannot work — see frag/90). Both ports
# must be named explicitly: any Port line suppresses sshd's default 22
# entirely, so a 2222-only drop-in silently kills the desktop's port-22 path
# (A-01.13, devctl/vmctl) — observed live as connection-refused with the
# filter correctly admitting. Restart only
# on change: a restart is safe for existing sessions (they persist), but a
# pointless one on every re-run is noise and risk for nothing.
SSHD_DROPIN="${ROOT}/etc/ssh/sshd_config.d/nested-dev-2222.conf"
mkdir -p "$(dirname "$SSHD_DROPIN")"
printf 'Port 22\nPort 2222\n' > "${SSHD_DROPIN}.new"
if ! cmp -s "${SSHD_DROPIN}.new" "$SSHD_DROPIN" 2>/dev/null; then
    mv "${SSHD_DROPIN}.new" "$SSHD_DROPIN"
    sshd -t || die "sshd config test failed after adding Port 2222"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null \
        || log "WARNING: sshd restart failed — Port 2222 takes effect on next restart"
    log "sshd now listens on 22 (desktop) and 2222 (LAN management)"
else
    rm -f "${SSHD_DROPIN}.new"
    log "sshd already listens on 22 and 2222"
fi

log "=== desktop-control setup complete ==="
