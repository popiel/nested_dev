#!/usr/bin/env bash
# frag/90-finalize.sh — Firewall, host naming, build record
# The private network itself (bridge addressing, dnsmasq, forwarding, NAT) is
# frag/28-network.sh, which runs before any guest boots: guests need DHCP, DNS
# and egress while they install. This fragment keeps the parts that come
# after: the filter rules with fail-closed defaults, host naming and DNS, and
# the build record. It assumes the network is up and dies otherwise — a
# firewall over an unaddressed bridge would filter traffic that cannot flow.
# Idempotent. REF: __GITHUB_REF__
set -euo pipefail

ROOT="${PVE_ROOT:-}"
# /proc is a kernel interface, not a provisioner output. Overridable for the
# end-to-end test, which supplies a fixture meminfo.
PROC="${PVE_PROC:-/proc}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }
die() { log "FATAL: $*"; exit 1; }

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

# The private bridge must already carry its address: frag/28 brings it up
# before any guest boots, and filtering a bridge with no address filters
# nothing while claiming otherwise.
if ! ip -o addr show dev vmbr0 2>/dev/null | grep -q '192\.168\.100\.1/24'; then
    die "vmbr0 has no 192.168.100.1/24; frag/28-network.sh did not run or did not converge"
fi

# ============================================================
# 2. Install iptables-persistent
# ============================================================
if ! dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    log "iptables-persistent installed"
fi

# ============================================================
# 3. Apply iptables rules
# ============================================================
# LAN: 192.168.14.0/24 (external DHCP)
# VM subnet: 192.168.100.0/24
# $PHYS_NIC = LAN-facing interface
#
# Policies are set LAST, after every ACCEPT rule below. Setting DROP first
# strands the chain — including the operator's own SSH session — in the window
# before its exceptions exist, and a fragment that dies mid-section (as
# observed) then leaves a half-built ruleset under fail-closed defaults with
# no way back in except the console.

# --- NAT table ---
iptables -t nat -F PREROUTING
iptables -t nat -F POSTROUTING

# LAN → desktop: SSH (port 22) DNAT
iptables -t nat -A PREROUTING -i "$PHYS_NIC" -p tcp --dport 22 \
    -j DNAT --to-destination 192.168.100.100:22

# LAN → desktop: VNC console mirror (port 5900) DNAT. xrdp spawns separate
# sessions and can never mirror the physical console (R-02.2.1); x11vnc
# scrapes the live :0 instead, and this is how it is reached from the LAN.
iptables -t nat -A PREROUTING -i "$PHYS_NIC" -p tcp --dport 5900 \
    -j DNAT --to-destination 192.168.100.100:5900

# LAN → host SSH is on port 2222, served by sshd listening on 2222 directly
# (frag/25). Deliberately NOT a DNAT 2222→host:22: DNAT rewrites the port in
# PREROUTING, so the filter would see dport 22 from a LAN source and drop it
# — the INPUT dport-2222 rule below could never match a DNAT'd packet, and no
# listener ever existed on 2222. That combination meant host SSH from the LAN
# never worked in any topology.

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

# DHCP + DNS for guests on vmbr0 (dnsmasq serves this bridge). Without these,
# guests get no address and no resolver: every installer stalls before writing
# a byte, and the provisioning gate times out on guests that never started.
# Scoped to the private bridge, which has no physical ports, so this reaches
# guests and nothing else.
iptables -A INPUT -i vmbr0 -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i vmbr0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i vmbr0 -p tcp --dport 53 -j ACCEPT

log "INPUT rules applied"

# --- filter table: FORWARD ---
iptables -F FORWARD

# Desktop (192.168.100.100) can reach anyone on vmbr0 (SSH, X11 forwarding)
iptables -A FORWARD -i vmbr0 -o vmbr0 -s 192.168.100.100 -j ACCEPT

# LAN → desktop: the PREROUTING DNAT rules rewrite these destinations, but
# rewritten packets still traverse FORWARD — without explicit accepts here the
# documented SSH/VNC access is translated and then silently dropped.
iptables -A FORWARD -i "$PHYS_NIC" -o vmbr0 -p tcp -d 192.168.100.100 --dport 22 -j ACCEPT
iptables -A FORWARD -i "$PHYS_NIC" -o vmbr0 -p tcp -d 192.168.100.100 --dport 5900 -j ACCEPT

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
# Dev template (102): DNS/HTTP/HTTPS while it provisions, for the same fetches
#   (its first boot pulls container images and the Ubuntu archive). It never
#   auto-starts after conversion to template, so this allowance in practice
#   serves the one provisioning run, not a running machine.
# All other dev VMs (104-249): no egress. Their toolchain is baked into
#   template 102, so a clone never needs to reach the network.

# Desktop (100): unrestricted by design — it is the bastion and browses.
# Without this rule the desktop has no route off vmbr0 at all, and the
# "unrestricted" claim in the comment above is not backed by a rule.
iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s 192.168.100.100 -j ACCEPT

# LLM (101), dev template (102), trusted builder (103): DNS, HTTP, HTTPS only.
# DNS is allowed over both UDP and TCP: a truncated or oversized answer falls
# back to TCP, and a resolver that only speaks UDP fails exactly when the guest
# most needs an answer. The host's own OUTPUT chain below allows both for the
# same reason.
#
# The template is on this list because it builds the toolchain its clones run:
# dev-firstboot.sh fetches from GitHub and the Ubuntu archive and pulls
# container images, which is all HTTPS (plus DNS). A template that cannot
# reach its sources cannot provision, and the provisioning gate waits on the
# log line that only a provisioned template writes. The template never
# auto-starts after conversion, so in practice these rules serve its one
# provisioning run, not a running fleet.
for EGRESS_IP in 192.168.100.101 192.168.100.102 192.168.100.103; do
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -i vmbr0 -o "$PHYS_NIC" -s "$EGRESS_IP" \
        -p tcp --dport 443 -j ACCEPT
done
log "FORWARD egress: 100 unrestricted; 101 + 102 + 103 allowed 53/80/443; other dev VMs denied"

# Return traffic for established connections
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

log "FORWARD rules applied"

# --- filter table: OUTPUT (host egress: HTTP/HTTPS/DNS/NTP only) ---
iptables -F OUTPUT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# HTTPS (443) and HTTP (80). HTTP is not a lapse: the Debian, Ubuntu and
# Proxmox archives are HTTP-only (there is no TLS endpoint to allow instead),
# so without it the host cannot update or install anything past lockdown —
# which this very fragment does to later fragments on every re-run.
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT

# DNS (53)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# NTP (123)
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT

# ICMP echo (ping) outbound. Replies come back through ESTABLISHED,RELATED
# above (conntrack, which every reply path here already depends on). Without
# this the host cannot ping anything it is allowed to talk to — a diagnostic
# blackhole in a firewall the operator debugs from behind.
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT

# Replies to the vmbr0 services above: dnsmasq's DHCP offers/acks and DNS
# answers leave via the bridge. Without these the requests arrive and the
# answers die here — same silent stall, one chain further along.
iptables -A OUTPUT -o vmbr0 -p udp --sport 67 --dport 68 -j ACCEPT
iptables -A OUTPUT -o vmbr0 -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -o vmbr0 -p tcp --sport 53 -j ACCEPT

log "OUTPUT rules applied (host HTTP/HTTPS/DNS/NTP/ICMP-echo + vmbr0 service replies)"

# --- Set DROP defaults (fail-closed), after every exception above ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
log "Default policies set to DROP"

# Save rules (after the policies, so a reboot restores fail-closed, not open)
netfilter-persistent save
log "iptables rules saved"

# ============================================================
# 4. Configure host DNS to use dnsmasq
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
# 5. Write /etc/hosts with VM entries
# ============================================================
# The node itself resolves to its LAN address — never loopback. pmxcfs
# refuses to start when the node name resolves to 127.x (it needs a
# non-loopback identity for the node), so the Debian 127.0.1.1 convention
# bricks every reboot: the first boot works (the installer wrote a real
# entry), this file clobbers it, and pve-cluster can never restart. The
# address comes from nested-node-hosts.sh --print-ip (single implementation,
# shared with the maintenance wiring below); fail loudly with no address,
# since nothing downstream of a missing LAN address can succeed either.
NODE_MAINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/nested-node-hosts.sh"
NODE_IP="$(bash "$NODE_MAINT" --print-ip)" \
    || die "cannot determine node LAN address — cannot write node hosts entry"
cat > "${ROOT}/etc/hosts" <<HOSTS_EOF
127.0.0.1       localhost

${NODE_IP} lychee-host.wolfskeep.com lychee-host

# VM static entries (MACs match frag/30 qm create --net0)
192.168.100.100 lychee.wolfskeep.com lychee
192.168.100.101 lychee-llm.wolfskeep.com lychee-llm
192.168.100.102 lychee-dev-template.wolfskeep.com lychee-dev-template
HOSTS_EOF
log "/etc/hosts updated with VM entries (node=${NODE_IP})"

# --- 5b. Node-hosts maintenance: cron + lease-watcher ---
# No DHCP reservations exist here, so the entry above rots on every lease
# change and the next reboot fails in pmxcfs again. The same script maintains
# it: a systemd path unit fires on lease renewal, cron covers anything else.
install -m 0755 "$NODE_MAINT" "${ROOT}/usr/local/sbin/nested-node-hosts"
mkdir -p "${ROOT}/etc/cron.d"
cat > "${ROOT}/etc/cron.d/nested-node-hosts" <<'CRON_EOF'
# Refresh the node's /etc/hosts entry from the live LAN address (pmxcfs
# needs a non-loopback node identity). Installed by frag/90.
*/15 * * * * root /usr/local/sbin/nested-node-hosts
CRON_EOF
LEASE_FILE="/var/lib/dhcp/dhclient.${PHYS_NIC}.leases"
mkdir -p "${ROOT}/etc/systemd/system"
cat > "${ROOT}/etc/systemd/system/nested-node-hosts.service" <<'SVC_EOF'
[Unit]
Description=Refresh node hosts entry after lease change
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nested-node-hosts
SVC_EOF
cat > "${ROOT}/etc/systemd/system/nested-node-hosts.path" <<PATH_EOF
[Unit]
Description=Watch DHCP lease for node-hosts maintenance
[Path]
PathChanged=${LEASE_FILE}
[Install]
WantedBy=multi-user.target
PATH_EOF
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now nested-node-hosts.path 2>/dev/null \
    || log "WARNING: could not enable lease-watcher (cron backstop still active)"
log "node-hosts maintenance installed (cron + lease watcher on ${LEASE_FILE})"

# ============================================================
# 6. Hostname
# ============================================================
hostnamectl set-hostname lychee-host.wolfskeep.com
log "Hostname set to lychee-host.wolfskeep.com"

# ============================================================
# 7. Dev VM control (vmctl)
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
# 8. Record build info
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
# 9. MOTD
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
  VNC console mirror: <LAN-IP>:5900
  Logs: /var/log/pve-firstboot.log
  Dev control: devctl list/start/stop/add
========================================

EOF

log "=== Finalize complete ==="
