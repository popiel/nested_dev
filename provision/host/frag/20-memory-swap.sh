#!/usr/bin/env bash
# frag/20-memory-swap.sh — ZRAM + swap for 32 GB host profile
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

log() { printf '%s %s\n' "$(date -Is)" "$*" >> /var/log/pve-firstboot.log; }

log "=== Memory/swap setup ==="

# --- ZRAM (compressed memory) ---
if ! dpkg -l zram-tools 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    apt-get install -y zram-tools
    log "zram-tools installed"
fi

# Configure zram: zstd, 50% of RAM, high priority
cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

systemctl enable --now zramswap
log "ZRAM enabled (zstd, 50%)"

# --- Disk swap (4 GB file) ---
SWAPFILE="/swapfile"
if [ ! -f "$SWAPFILE" ]; then
    fallocate -l 4G "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    log "Swap file created (4 GB)"
fi

if ! grep -q "^/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if ! swapon --show | grep -q "$SWAPFILE"; then
    swapon -a
    log "Swap activated"
fi

# --- Memory balloon guidance ---
# QEMU balloon is enabled per-VM at creation time (frag/30).
# Host hard-capped at 2 GB via PVE resource limits.
# On 32 GB hosts: ZRAM handles RAM pressure; balloon gives back to host.

log "=== Memory/swap setup complete ==="
