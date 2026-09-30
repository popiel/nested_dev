#!/usr/bin/env bash
# frag/90-finalize.sh — Final host configuration, networking, screening
# Routed network: $PHYS_NIC = LAN (DHCP), vmbr0 = private (192.168.100.1/24)
# dnsmasq on host serves DHCP/DNS to VMs on vmbr0.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"
# /proc is a kernel interface, not a provisioner output. Overridable for the
# end-to-end test, which supplies a fixture meminfo.
PROC="${PVE_PROC:-/proc}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }

log "=== Finalize ==="

# NOTE: repository selection is owned by frag/05-apt-repos.sh, which runs
# before any fragment that calls apt. This fragment used to carry its own copy
# — move the enterprise list aside and write a hardcoded `bookworm`
# no-subscription line — and on a trixie host where frag/05 had already run it
# was dead code, while on a host where frag/05 had not run it wrote a
# repository for the wrong distribution. One owner, in one place.

# ============================================================
# 1. Detect physical NIC
# ============================================================
PHYS_NIC=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E 'lo|vmbr|docker|veth|br-' | head -1)
if [ -z "$PHYS_NIC" ]; then
    log "ERROR: No physical NIC detected"
    PHYS_NIC="CHANGE_ME_DETECT_AT_PROVISION"
else
    log "Detected physical NIC: $PHYS_NIC"
fi

# ============================================================
# 2. Write network config — routed architecture
# ============================================================
mkdir -p "${ROOT}/etc/network"
cat > "${ROOT}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

# Physical NIC — LAN-facing, DHCP from external server
auto ${PHYS_NIC}
iface ${PHYS_NIC} inet dhcp

# Private bridge — VM-facing, static IP, dnsmasq serves DHCP/DNS
auto vmbr0
iface vmbr0 inet static
    address 192.168.100.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
log "Network config written: ${PHYS_NIC} (DHCP) + vmbr0 (192.168.100.1/24)"

# Apply networking
if ! ip link show vmbr0 >/dev/null 2>&1; then
    systemctl restart networking
    log "Networking restarted"
else
    log "vmbr0 already exists — skipping restart"
fi

# ============================================================
# 3. Install and configure dnsmasq
# ============================================================
if ! dpkg -l dnsmasq 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
    log "dnsmasq installed"
fi

# Write dnsmasq config (static leases + DNS for VMs)
mkdir -p "${ROOT}/etc/dnsmasq.d"
cat > "${ROOT}/etc/dnsmasq.d/nested_dev.conf" <<'DNSMASQ_EOF'
# dnsmasq config for nested_dev — served on vmbr0 (192.168.100.0/24)
interface=vmbr0
bind-interfaces

# DHCP range for ad-hoc / future VMs
dhcp-range=192.168.100.110,192.168.100.200,255.255.255.0,12h

# Default gateway and DNS for DHCP clients
dhcp-option=option:router,192.168.100.1
dhcp-option=option:dns-server,192.168.100.1

# --- Static leases (MACs match frag/30 qm create --net0) ---
dhcp-host=52:54:00:00:01:00,lychee,192.168.100.100
dhcp-host=52:54:00:00:01:01,lychee-llm,192.168.100.101
dhcp-host=52:54:00:00:01:02,lychee-dev-template,192.168.100.102

# --- DNS: short names + FQDNs ---
address=/lychee-host/192.168.100.1
address=/lychee-host.wolfskeep.com/192.168.100.1
address=/lychee/192.168.100.100
address=/lychee.wolfskeep.com/192.168.100.100
address=/lychee-llm/192.168.100.101
address=/lychee-llm.wolfskeep.com/192.168.100.101
address=/lychee-dev-template/192.168.100.102
address=/lychee-dev-template.wolfskeep.com/192.168.100.102

# Upstream DNS from host's DHCP-provided resolv.conf
resolv-file=/run/resolv.conf
DNSMASQ_EOF

# Disable dnsmasq's own resolv.conf management (we provide upstream via resolv-file)
sed -i 's|^#resolv-file=.*|resolv-file=/run/resolv.conf|' "${ROOT}/etc/dnsmasq.conf" 2>/dev/null || true

systemctl enable --now dnsmasq
log "dnsmasq configured and started"

# ============================================================
# 4. Enable IP forwarding
# ============================================================
mkdir -p "${ROOT}/etc/sysctl.d"
cat > "${ROOT}/etc/sysctl.d/99-nested-dev.conf" <<'SYSCTL_EOF'
# Enable IPv4 forwarding for routed VM network
net.ipv4.ip_forward = 1
SYSCTL_EOF
sysctl -w net.ipv4.ip_forward=1
log "IP forwarding enabled"

# ============================================================
# 5. Install iptables-persistent
# ============================================================
if ! dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    log "iptables-persistent installed"
fi

# ============================================================
# 6. Apply iptables rules
# ============================================================
# LAN: 192.168.14.0/24 (external DHCP)
# VM subnet: 192.168.100.0/24
# $PHYS_NIC = LAN-facing interface

# --- Set DROP defaults (fail-closed) ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
log "Default policies set to DROP"

# --- NAT table ---
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING

# LAN → desktop: SSH (port 22) DNAT
iptables -t nat -A PREROUTING -i "$PHYS_NIC" -p tcp --dport 22 \
    -j DNAT --to-destination 192.168.100.100:22

# LAN → desktop: RDP (port 3389) DNAT
iptables -t nat -A PREROUTING -i "$PHYS_NIC" -p tcp --dport 3389 \
    -j DNAT --to-destination 192.168.100.100:3389

# LAN → host: SSH on port 2222 (192.168.14.* only) → host:22
iptables -t nat -A PREROUTING -i "$PHYS_NIC" -s 192.168.14.0/24 -p tcp --dport 2222 \
    -j DNAT --to-destination 192.168.100.1:22

# VM egress: MASQUERADE from private subnet to LAN
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$PHYS_NIC" -j MASQUERADE

log "NAT rules applied"

# --- filter table: INPUT ---
iptables -F INPUT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH to host on port 2222 — LAN only
iptables -A INPUT -p tcp --dport 2222 -s 192.168.14.0/24 -j ACCEPT

# SSH to host from desktop only (for vmctl/devctl control)
iptables -A INPUT -p tcp --dport 22 -s 192.168.100.100 -j ACCEPT

# PVE web UI — LAN only
iptables -A INPUT -p tcp --dport 8006 -s 192.168.14.0/24 -j ACCEPT

# ICMP
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

log "INPUT rules applied"

# --- filter table: FORWARD ---
iptables -F FORWARD

# Desktop (192.168.100.100) can reach anyone on vmbr0 (SSH, X11 forwarding)
iptables -A FORWARD -i vmbr0 -o vmbr0 -s 192.168.100.100 -j ACCEPT

# --- Guest egress policy ---
# FORWARD governs traffic between a VM and the LAN; the OUTPUT chain below
# governs only the host's own traffic and does not restrict guests. MASQUERADE
# (above) handles the return path, so each allowance here needs a matching
# protocol filter or the guest gets a black hole.
#
# Desktop (100): unrestricted by design — it is the bastion and browses.
# LLM (101): DNS/HTTP/HTTPS. It installs the driver/CUDA/Docker stack and pulls
#   Ollama images and models on first boot, so it cannot be air-gapped.
# dev-nested (103): DNS/HTTP/HTTPS. This is the trusted ISO builder; it fetches
#   from GitHub, the Ubuntu archive and the PVE ISO mirror.
# All other dev VMs (104-249): no egress. Their toolchain is baked into
#   template 102 during the pre-firewall provisioning window and is cloned
#   already-provisioned, so a clone never needs to reach the network.

# Desktop (100): unrestricted by design — it is the bastion and browses.
# Without this rule the desktop has no route off vmbr0 at all, and the
# "unrestricted" claim in the comment above is not backed by a rule.
iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s 192.168.100.100 -j ACCEPT

# LLM + trusted builder: DNS, HTTP, HTTPS only.
# DNS is allowed over both UDP and TCP: a truncated or oversized answer falls
# back to TCP, and a resolver that only speaks UDP fails exactly when the guest
# most needs an answer. The host's own OUTPUT chain below allows both for the
# same reason.
for EGRESS_IP in 192.168.100.101 192.168.100.103; do
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 443 -j ACCEPT
done
log "FORWARD egress: 100 unrestricted; 101 + 103 allowed 53/80/443; other dev VMs denied"

# Return traffic for established connections
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

log "FORWARD rules applied"

# --- filter table: OUTPUT (host egress: HTTPS/DNS/NTP only) ---
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# HTTPS (443)
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

# DNS (53)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# NTP (123)
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT

log "OUTPUT rules applied (HTTPS/DNS/NTP only)"

# Save rules
netfilter-persistent save
log "iptables rules saved"

# ============================================================
# 7. Configure host DNS to use dnsmasq
# ============================================================
# Point host resolver at dnsmasq (127.0.0.1) for VM name resolution
# dnsmasq forwards external queries to upstream DNS from /run/resolv.conf
cat > "${ROOT}/etc/resolv.conf" <<'RESOLV_EOF'
# Managed by frag/90-finalize.sh — host uses dnsmasq for DNS
# dnsmasq resolves VM names and forwards external queries upstream
nameserver 127.0.0.1
RESOLV_EOF
log "Host DNS configured to use dnsmasq (127.0.0.1)"

# ============================================================
# 8. Write /etc/hosts with VM entries
# ============================================================
cat > "${ROOT}/etc/hosts" <<'HOSTS_EOF'
127.0.0.1       localhost
127.0.1.1       lychee-host.wolfskeep.com lychee-host

# VM static entries (MACs match frag/30 qm create --net0)
192.168.100.100 lychee.wolfskeep.com lychee
192.168.100.101 lychee-llm.wolfskeep.com lychee-llm
192.168.100.102 lychee-dev-template.wolfskeep.com lychee-dev-template
HOSTS_EOF
log "/etc/hosts updated with VM entries"

# ============================================================
# 9. Hostname
# ============================================================
hostnamectl set-hostname lychee-host.wolfskeep.com
log "Hostname set to lychee-host.wolfskeep.com"

# ============================================================
# 10. Dev VM control (vmctl)
# ============================================================
# Ensure dnsmasq dev drop-in exists
if [ ! -f "${ROOT}/etc/dnsmasq.d/zz-dev.conf" ]; then
    mkdir -p "${ROOT}/etc/dnsmasq.d"
    echo "# Per-project dev VMs — added by vmctl-host on demand" > "${ROOT}/etc/dnsmasq.d/zz-dev.conf"
    log "dnsmasq dev drop-in created"
fi

# Ensure inventory exists
if [ ! -f "${ROOT}/etc/nested-dev/inventory" ]; then
    mkdir -p "${ROOT}/etc/nested-dev"
    cat > "${ROOT}/etc/nested-dev/inventory" <<'EOF'
# VMID  NAME  HOSTNAME  IP  MAC  STATUS  PROJECT
100  desktop  lychee  192.168.100.100  52:54:00:00:01:00  running  desktop
101  llm  lychee-llm  192.168.100.101  52:54:00:00:01:01  running  llm
102  dev-template  lychee-dev-template  192.168.100.102  52:54:00:00:01:02  template  dev-template
EOF
    log "Inventory created"
fi

# ============================================================
# 10. Record build info
# ============================================================
mkdir -p "${ROOT}/root/output"
cat > "${ROOT}/root/output/MANIFEST" <<EOF
# nested_dev host build manifest
# REF: __GITHUB_REF__
# Built: $(date -Is)
# PVE version: $(pveversion 2>/dev/null || echo "unknown")
# CPU: $(lscpu | awk '/Model name/{print $0}')
# RAM: $(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' "${PROC}/meminfo")
# Disks: $(lsblk -dno NAME,SIZE,ROTA | grep -v loop | tr '\n' '; ')
# GPUs: $(lspci | grep -iE 'vga|3d' | tr '\n' '; ')
# Network: routed (PHYS_NIC=$PHYS_NIC, vmbr0=192.168.100.1/24)
# DNS: dnsmasq on 127.0.0.1
EOF
log "Manifest written to ${ROOT}/root/output/MANIFEST"

# ============================================================
# 11. MOTD
# ============================================================
cat > "${ROOT}/etc/motd" <<'EOF'

========================================
  lychee-host — Proxmox VE 9.2
  nested_dev main
  Routed network (192.168.100.0/24)
========================================
  VMs: 100=desktop, 101=llm, 102=dev-template
  Dev VMs: on demand via devctl from desktop
  PVE UI: https://<LAN-IP>:8006
  SSH to host: ssh -p 2222 root@<LAN-IP>
  SSH to desktop: ssh root@<LAN-IP> (DNAT)
  RDP to desktop: mstsc <LAN-IP>:3389
  Logs: /var/log/pve-firstboot.log
  Dev control: devctl list/start/stop/add
========================================

EOF

log "=== Finalize complete ==="
