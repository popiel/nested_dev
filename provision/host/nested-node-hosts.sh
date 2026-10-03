#!/usr/bin/env bash
# provision/host/nested-node-hosts.sh — keep the node's /etc/hosts entry true.
#
# The node name must resolve to its LAN address, never loopback: pmxcfs
# refuses a loopback node identity and pve-cluster can never (re)start, so a
# stale entry bricks every reboot while everything else looks healthy. DHCP
# provides no reservations here, so the entry is re-derived from the live
# interface rather than trusted from provision time.
#
# Usage: nested-node-hosts.sh [--print-ip]
#   no args: detect the LAN NIC's IPv4 and rewrite the node line if stale;
#     no-op when correct or when no address is detectable. Tolerant by
#     design: cron and the lease-watcher call this unsupervised, and a
#     transient boot state must warn, not die.
#   --print-ip: print the detected address, or die. Strict by design: frag/90
#     calls this for the initial file, where no address means nothing
#     downstream can succeed.
#
# NIC choice mirrors frag/90's PHYS_NIC detection (first non-loopback,
# non-virtual NIC); the IP derivation lives here alone, and frag/90 calls
# --print-ip rather than reimplementing it.
#
# ROOT="${PVE_ROOT:-}" throughout, same contract as the fragments, so the
# unit tests drive this against scratch. The FQDN aliases are this
# deployment's constants, matching frag/90's hosts block.
set -euo pipefail

ROOT="${PVE_ROOT:-}"
HOSTS_FILE="${ROOT}/etc/hosts"
NODE_FQDN="lychee-host.wolfskeep.com"
NODE_SHORT="lychee-host"

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${ROOT}/var/log/pve-firstboot.log"; }

detect_nic() {
    ip -o link show 2>/dev/null \
        | awk -F': ' '{print $2}' \
        | grep -v -E 'lo|vmbr|docker|veth|br-' \
        | head -1
}

nic_ip() {
    local nic="$1"
    ip -o addr show dev "$nic" 2>/dev/null \
        | awk -v nic="$nic" '$2 == nic && $3 == "inet" {split($4, a, "/"); print a[1]; exit}'
}

current_node_ip() {
    awk -v fqdn="$NODE_FQDN" '$0 ~ fqdn {print $1; exit}' "$HOSTS_FILE" 2>/dev/null || true
}

if [ "${1:-}" = "--print-ip" ]; then
    NIC="$(detect_nic)"
    [ -n "$NIC" ] || { log "FATAL: no LAN NIC detected"; exit 1; }
    IP="$(nic_ip "$NIC")"
    [ -n "$IP" ] || { log "FATAL: no IPv4 address on ${NIC}"; exit 1; }
    printf '%s\n' "$IP"
    exit 0
fi

# Update mode: tolerant. Every early exit warns (cron-visible) but succeeds,
# because a lease that has not arrived yet is not an error.
NIC="$(detect_nic || true)"
if [ -z "$NIC" ]; then
    log "nested-node-hosts: no LAN NIC yet, leaving ${HOSTS_FILE} alone"
    exit 0
fi
IP="$(nic_ip "$NIC" || true)"
if [ -z "$IP" ]; then
    log "nested-node-hosts: no IPv4 on ${NIC} yet, leaving ${HOSTS_FILE} alone"
    exit 0
fi
if [ ! -f "$HOSTS_FILE" ]; then
    log "nested-node-hosts: no ${HOSTS_FILE}, nothing to maintain"
    exit 0
fi
HAVE="$(current_node_ip || true)"
if [ "$HAVE" = "$IP" ]; then
    exit 0
fi
awk -v ip="$IP" -v fqdn="$NODE_FQDN" -v short="$NODE_SHORT" '
    $0 ~ fqdn && !done {print ip " " fqdn " " short; done=1; next}
    {print}
    END {if (!done) print ip " " fqdn " " short}
' "$HOSTS_FILE" > "${HOSTS_FILE}.new"
mv "${HOSTS_FILE}.new" "$HOSTS_FILE"
log "nested-node-hosts: node entry ${HAVE:-<missing>} -> ${IP}"
